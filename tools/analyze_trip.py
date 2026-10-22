#!/usr/bin/env python3
"""Analyze local sensor JSONL; railway distances are evaluation inputs, never corrections."""
import argparse
import csv
import json
import math
from pathlib import Path


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def integrate(points, start, end, max_gap):
    """Piecewise-linear speed integral with clipped bounds and explicit uncovered time."""
    if not all(finite(x) for x in (start, end, max_gap)) or end <= start or max_gap <= 0:
        raise ValueError('积分区间或采样间隔无效')
    meters = covered = 0.0
    cursor = start
    longest_gap = 0.0
    last = None
    for timestamp, speed in points:
        if not finite(timestamp):
            raise ValueError('存在无效时间戳')
        if last and timestamp < last[0]:
            raise ValueError('数据时间倒退，不能直接积分')
        valid = finite(speed) and speed >= 0
        if last and valid and last[1] is not None:
            t0, v0 = last
            dt = timestamp - t0
            lo, hi = max(t0, start), min(timestamp, end)
            if 0 < dt <= max_gap and hi > lo:
                left = v0 + (speed - v0) * (lo - t0) / dt
                right = v0 + (speed - v0) * (hi - t0) / dt
                meters += (left + right) * .5 * (hi - lo)
                covered += hi - lo
                longest_gap = max(longest_gap, lo - cursor)
                cursor = hi
        last = (timestamp, speed if valid else None)
    longest_gap = max(longest_gap, end - cursor)
    duration = end - start
    complete = duration - covered <= 1e-6
    return {
        'observedDistanceMeters': meters,
        'estimatedDistanceMeters': meters if complete else None,
        'coveredSeconds': covered,
        'durationSeconds': duration,
        'coverageFraction': min(1.0, covered / duration),
        'longestGapSeconds': longest_gap,
        'averageSpeedKmh': meters / duration * 3.6 if complete else None,
    }


def extract_points(events):
    recorded, raw = [], []
    for event in events:
        now = event['receivedAt']
        if event.get('reset') or event.get('resetSpeedOnly'):
            recorded.append((now, None))
        elif 'recordedEstimate' in event:
            estimate = event['recordedEstimate']
            recorded.append((now, estimate.get('speed') if estimate.get('state') != 'unavailable' else None))
        if 'speed' in event:
            fix = event['speed']
            v, accuracy, horizontal = fix.get('speed'), fix.get('speedAccuracy'), fix.get('horizontalAccuracy')
            valid = (finite(v) and 0 <= v <= 140 and finite(accuracy) and 0 <= accuracy <= 5
                     and finite(horizontal) and 0 <= horizontal <= 100)
            timestamp = fix.get('timestamp')
            # Raw baseline retains physical jumps; it is a comparison, not independent truth.
            if finite(timestamp) and (not raw or timestamp > raw[-1][0]):
                raw.append((timestamp, v if valid else None))
    return recorded, raw


def compare(points, start, end, max_gap, reference):
    result = integrate(points, start, end, max_gap)
    distance = result['estimatedDistanceMeters']
    result['distanceErrorMeters'] = distance - reference if distance is not None else None
    result['distanceErrorPercent'] = (distance - reference) / reference * 100 if distance is not None else None
    return result


def analyze(events, segments, replay_points=None):
    if not events:
        raise ValueError('记录为空')
    markers = {}
    for event in events:
        if 'marker' in event:
            timestamp = event['marker'].get('timestamp')
            effective_time = timestamp if finite(timestamp) and events[0]['receivedAt'] <= timestamp <= event['receivedAt'] else event['receivedAt']
            marker = {**event['marker'], 'receivedAt': effective_time, 'respondedAt': event['receivedAt']}
            if marker['id'] in markers:
                raise ValueError('重复的标记 ID: ' + marker['id'])
            markers[marker['id']] = marker
    recorded, raw = extract_points(events)
    results, windows = [], []
    for segment in segments:
        try:
            start = markers[segment['startMarker']]['receivedAt']
            end = markers[segment['endMarker']]['receivedAt']
        except KeyError as error:
            raise ValueError(f'站间信息引用了不存在的标记或字段: {error}') from error
        reference = segment.get('distanceMeters')
        if not finite(reference) or reference <= 0 or not segment.get('source'):
            raise ValueError('每段需填写正数 distanceMeters 和距离来源 source')
        if end <= start:
            raise ValueError('结束标记必须晚于起始标记')
        if any(start < b and end > a for a, b in windows):
            raise ValueError('参考区间不能重叠，否则全程统计会重复计数')
        windows.append((start, end))
        row = {**segment, 'startTime': start, 'endTime': end,
               'referenceAverageSpeedKmh': reference / (end - start) * 3.6,
               'recorded': compare(recorded, start, end, 1, reference),
               'rawLocationSpeed': compare(raw, start, end, 2.5, reference)}
        if replay_points is not None:
            row['replay'] = compare(replay_points, start, end, 1, reference)
        results.append(row)
    totals = {}
    for stream in ['recorded', 'rawLocationSpeed'] + (['replay'] if replay_points is not None else []):
        complete = [s for s in results if s[stream]['estimatedDistanceMeters'] is not None]
        differences = [s[stream]['distanceErrorMeters'] for s in complete]
        reference = sum(s['distanceMeters'] for s in complete)
        totals[stream] = {
            'completeSegments': len(complete), 'totalSegments': len(results),
            'referenceMetersOnCompleteSegments': reference,
            'distanceErrorMetersOnCompleteSegments': sum(differences) if complete else None,
            'absoluteDistanceErrorMetersOnCompleteSegments': sum(map(abs, differences)) if complete else None,
            'weightedAbsoluteDistanceErrorPercent': sum(map(abs, differences)) / reference * 100 if reference else None,
        }
    return {
        'metadata': next((e['metadata'] for e in events if 'metadata' in e), {}),
        'endedNormally': any(e.get('lifecycle') == 'recordingEnded' for e in events),
        'eventCount': len(events), 'markers': list(markers.values()),
        'sensorEventCounts': {key: sum(key in e for e in events) for key in
                              ['speed', 'rawMotion', 'accelerometer', 'gyroscope', 'magnetometer', 'pressure', 'sensorError']},
        'segments': results, 'totals': totals,
        'railArrivals': {
            'candidates': [e['railCandidate'] for e in events if 'railCandidate' in e],
            'resolutions': [e['railResolution'] for e in events if 'railResolution' in e],
            'answers': {answer: sum(e.get('railResolution', {}).get('answer') == answer for e in events)
                        for answer in ['confirmed', 'denied', 'unanswered']},
        },
        'interpretation': '完整区间才计算距离误差；定位速度仅作同源对照。距离吻合不等于瞬时速度准确。各流的完整区间可能不同，比较参数时需使用共同完整区间。',
    }


def load_events(path):
    events = []
    warnings = []
    with open(path, encoding='utf-8') as source:
        lines = source.readlines()
    previous = -math.inf
    for index, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError as error:
            if index == len(lines) and not line.endswith('\n'):
                warnings.append('末行未写完，已忽略；其余已落盘数据保留。')
                break
            raise ValueError(f'第 {index} 行不是有效 JSON') from error
        now = event.get('receivedAt')
        if not finite(now) or now < previous:
            raise ValueError(f'第 {index} 行 receivedAt 无效或倒退')
        events.append(event)
        previous = now
    return events, warnings


def template(events):
    result, departure = [], None
    for event in events:
        marker = event.get('marker', {})
        if marker.get('kind') == 'departure':
            departure = marker
        elif marker.get('kind') == 'arrival' and departure:
            result.append({'name': f"{departure.get('note') or departure['id']} → {marker.get('note') or marker['id']}",
                           'startMarker': departure['id'], 'endMarker': marker['id'],
                           'distanceMeters': None, 'source': ''})
            departure = None
    return result


def load_replay(path, events):
    with open(path, encoding='utf-8') as source:
        rows = [json.loads(line) for line in source if line.strip()]
    if len(rows) != len(events):
        raise ValueError('回放输出行数与原始输入不一致，不能配对')
    points = []
    for row, event in zip(rows, events):
        estimate = row['estimate']
        if estimate['timestamp'] != event['receivedAt']:
            raise ValueError('回放与原始输入时间不一致')
        # Compare old/new algorithms on the same recorded evaluation cadence.
        if 'recordedEstimate' in event or event.get('reset') or event.get('resetSpeedOnly'):
            points.append((estimate['timestamp'], estimate.get('speed') if estimate.get('state') != 'unavailable' else None))
    return points


def export_csv(path, events):
    fields = ['elapsedSeconds', 'receivedAt', 'measurementTime', 'rawSpeedMps', 'speedAccuracyMps',
              'recordedSpeedMps', 'modelUncertaintyMps', 'uncertaintyFloorMps', 'covarianceSpeedSigmaMps',
              'state', 'accelerationMps2', 'accelerometerBiasMps2', 'nis', 'result', 'markerID', 'markerKind', 'note']
    with open(path, 'w', encoding='utf-8-sig', newline='') as target:
        writer = csv.DictWriter(target, fieldnames=fields)
        writer.writeheader()
        for event in events:
            if 'recordedEstimate' not in event and 'speed' not in event and 'marker' not in event:
                continue
            estimate, fix = event.get('recordedEstimate', {}), event.get('speed', {})
            diag, marker = event.get('diagnostics', {}), event.get('marker', {})
            state = diag.get('state') or [None, None, None]
            writer.writerow(dict(zip(fields, [
                event['receivedAt'] - events[0]['receivedAt'], event['receivedAt'], fix.get('timestamp'),
                fix.get('speed'), fix.get('speedAccuracy'), estimate.get('speed'), estimate.get('uncertainty'),
                diag.get('uncertaintyFloor'), diag.get('covarianceSpeedSigma'), estimate.get('state'),
                state[1], state[2], diag.get('nis'), diag.get('lastResult'), marker.get('id'), marker.get('kind'), marker.get('note'),
            ])))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('session', type=Path)
    parser.add_argument('--segments', type=Path, help='站间距离 JSON 数组')
    parser.add_argument('--template', action='store_true', help='根据起步/到站标记生成待填距离模板')
    parser.add_argument('--replay', type=Path, help='speed-replay 逐行输出，用于比较修改后的算法')
    parser.add_argument('--csv', type=Path, help='导出速度和诊断曲线表格')
    args = parser.parse_args()
    try:
        events, warnings = load_events(args.session)
        if not events:
            raise ValueError('记录为空')
        if args.template:
            output = template(events)
        else:
            segments = json.loads(args.segments.read_text(encoding='utf-8')) if args.segments else []
            replay = load_replay(args.replay, events) if args.replay else None
            output = analyze(events, segments, replay)
            output['warnings'] = warnings
            if not output['endedNormally']:
                output['warnings'].append('未发现正常结束事件：可能是意外中断、写入失败或旧版日志。')
            if args.csv:
                export_csv(args.csv, events)
        print(json.dumps(output, ensure_ascii=False, indent=2, allow_nan=False))
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f'分析失败: {error}\n')


if __name__ == '__main__':
    main()
