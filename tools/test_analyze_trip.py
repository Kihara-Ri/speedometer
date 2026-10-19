import unittest
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from analyze_trip import integrate, analyze, load_events


class TripAnalysisTests(unittest.TestCase):
    def test_delayed_arrival_confirmation_uses_stop_time_and_keeps_feedback_labels(self):
        events = [
            {'receivedAt': 0, 'marker': {'id': 'M1', 'kind': 'departure'},
             'recordedEstimate': {'speed': 10, 'state': 'measured'}},
            {'receivedAt': 1, 'recordedEstimate': {'speed': 10, 'state': 'measured'}},
            {'receivedAt': 10, 'marker': {'id': 'M2', 'kind': 'arrival', 'timestamp': 1},
             'railCandidate': {'id': 'R1'},
             'railResolution': {'candidateID': 'R1', 'answer': 'confirmed'}},
            {'receivedAt': 11, 'railResolution': {'candidateID': 'R2', 'answer': 'unanswered'}},
        ]
        segments = [{'startMarker': 'M1', 'endMarker': 'M2', 'distanceMeters': 10, 'source': 'fixture'}]
        result = analyze(events, segments)
        self.assertEqual(result['segments'][0]['endTime'], 1)
        self.assertEqual(result['segments'][0]['recorded']['estimatedDistanceMeters'], 10)
        self.assertEqual(result['railArrivals']['answers'], {'confirmed': 1, 'denied': 0, 'unanswered': 1})

    def test_clips_trapezoids_at_reference_boundaries(self):
        # Linear v(t)=10t: integral from .25 to .75 is 2.5 m.
        result = integrate([(0, 0), (1, 10)], .25, .75, 1)
        self.assertAlmostEqual(result['observedDistanceMeters'], 2.5)
        self.assertAlmostEqual(result['coverageFraction'], 1)
        self.assertAlmostEqual(result['estimatedDistanceMeters'], 2.5)

    def test_missing_and_long_gaps_cannot_be_reported_as_complete_distance(self):
        result = integrate([(0, 10), (1, 10), (2, None), (3, 10), (4, 10), (10, 10)], 0, 10, 1)
        self.assertEqual(result['observedDistanceMeters'], 20)
        self.assertEqual(result['coverageFraction'], .2)
        self.assertIsNone(result['estimatedDistanceMeters'])
        self.assertEqual(result['longestGapSeconds'], 6)

    def test_station_comparison_does_not_correct_the_algorithm_using_reference(self):
        events = [
            {'receivedAt': 0, 'marker': {'id': 'M001', 'kind': 'departure', 'note': 'A'},
             'recordedEstimate': {'timestamp': 0, 'speed': 10, 'state': 'measured'}},
            {'receivedAt': 1, 'marker': {'id': 'M002', 'kind': 'arrival', 'note': 'B'},
             'recordedEstimate': {'timestamp': 1, 'speed': 10, 'state': 'measured'}},
            {'receivedAt': 1, 'lifecycle': 'recordingEnded'},
        ]
        segments = [{'name': 'A–B', 'startMarker': 'M001', 'endMarker': 'M002', 'distanceMeters': 8, 'source': 'fixture'}]
        report = analyze(events, segments)
        comparison = report['segments'][0]['recorded']
        self.assertEqual(comparison['estimatedDistanceMeters'], 10)
        self.assertEqual(comparison['distanceErrorMeters'], 2)
        self.assertEqual(comparison['distanceErrorPercent'], 25)

    def test_unknown_marker_and_overlapping_segments_fail(self):
        events = [{'receivedAt': 0, 'marker': {'id': 'M1', 'kind': 'departure'}},
                  {'receivedAt': 1, 'marker': {'id': 'M2', 'kind': 'arrival'}}]
        segment = {'name': 'test', 'startMarker': 'M1', 'endMarker': 'M2', 'distanceMeters': 8, 'source': 'fixture'}
        with self.assertRaises(ValueError):
            analyze(events, [{**segment, 'startMarker': 'unknown'}])
        with self.assertRaises(ValueError):
            analyze(events, [segment, segment])

    def test_opposite_station_errors_do_not_disappear_from_absolute_error_total(self):
        events = [
            {'receivedAt': t, 'marker': {'id': f'M{t}', 'kind': 'note'},
             'recordedEstimate': {'speed': speed, 'state': 'measured'}}
            for t, speed in [(0, 10), (1, 10), (2, 6), (3, 6)]
        ]
        segments = [{'name': 'first', 'startMarker': 'M0', 'endMarker': 'M1', 'distanceMeters': 8, 'source': 'fixture'},
                    {'name': 'second', 'startMarker': 'M2', 'endMarker': 'M3', 'distanceMeters': 8, 'source': 'fixture'}]
        totals = analyze(events, segments)['totals']['recorded']
        self.assertEqual(totals['distanceErrorMetersOnCompleteSegments'], 0)
        self.assertEqual(totals['absoluteDistanceErrorMetersOnCompleteSegments'], 4)
        self.assertEqual(totals['weightedAbsoluteDistanceErrorPercent'], 25)

    def test_recovers_truncated_tail_but_rejects_corrupt_complete_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'session.jsonl'
            path.write_text('{"receivedAt":0}\n{"rece', encoding='utf-8')
            events, warnings = load_events(path)
            self.assertEqual(len(events), 1)
            self.assertEqual(len(warnings), 1)
            path.write_text('{"receivedAt":0}\ninvalid\n', encoding='utf-8')
            with self.assertRaises(ValueError):
                load_events(path)

    def test_cli_generates_template_comparison_and_csv_from_exported_file(self):
        events = [{'receivedAt': 0, 'marker': {'id': 'M1', 'kind': 'departure', 'note': 'A'},
                   'recordedEstimate': {'timestamp': 0, 'speed': 10, 'state': 'measured'}},
                  {'receivedAt': 1, 'marker': {'id': 'M2', 'kind': 'arrival', 'note': 'B'},
                   'recordedEstimate': {'timestamp': 1, 'speed': 10, 'state': 'measured'}},
                  {'receivedAt': 1, 'lifecycle': 'recordingEnded'}]
        script = str(Path(__file__).with_name('analyze_trip.py'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session, segments, csv = root / 'session.jsonl', root / 'railway.json', root / 'samples.csv'
            session.write_text(''.join(json.dumps(e) + '\n' for e in events), encoding='utf-8')
            command = [sys.executable, script, str(session)]
            template = json.loads(subprocess.run(command + ['--template'], check=True, capture_output=True, text=True).stdout)
            self.assertEqual(template[0]['startMarker'], 'M1')
            self.assertIsNone(template[0]['distanceMeters'])
            template[0].update(distanceMeters=8, source='fixture')
            segments.write_text(json.dumps(template), encoding='utf-8')
            result = subprocess.run(command + ['--segments', str(segments), '--csv', str(csv)], check=True, capture_output=True, text=True)
            report = json.loads(result.stdout)
            self.assertEqual(report['segments'][0]['recorded']['distanceErrorMeters'], 2)
            self.assertTrue(report['endedNormally'])
            self.assertEqual(len(csv.read_text(encoding='utf-8-sig').splitlines()), 3)


if __name__ == '__main__':
    unittest.main()
