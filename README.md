# 测速计

一个原生 iOS 测速 App（Swift 6 / iOS 17+，SwiftUI）：用手机的定位和运动传感器实时显示速度，并自动判断你是在乘车还是靠自己出行。无服务器、无账户、无广告、无第三方依赖，数据只留在本机。

## 功能

- 仪表盘实时显示速度，支持 km/h、m/s、mph
- 最高速度、平均速度、里程统计；显示数据来源、不确定度和数据延迟
- 状态清晰：实测 / 推算中 / 搜索信号，权限问题给出明确提示
- 自动识别出行方式：乘车（`vehicle`）、步行/跑步/骑行（`independent`），证据不足时为 `unknown`
- 可选的传感器记录与离线回放，用于调参和复现问题

## 原理

速度直接取自 Core Location 的多普勒测速（`CLLocation.speed`）及其精度，**不**用相邻经纬度做差分，避免把位置误差放大成速度噪声。在此之上做滤波和合理性检查，信号中断时短暂推算，不可靠时宁可不显示。

## 算法

- **三状态卡尔曼滤波**：状态为速度、纵向加速度、加速度偏置。使用 Joseph 形式更新协方差；巡航时过程噪声小，检测到合理的明显加减速时自动调大，兼顾平稳与响应。
- **观测校验**：检查速度/精度有效性、时间戳、观测年龄、物理可达的加减速和标准化创新。单个跳点不会改变可信速度；持续一致的新观测才会重新捕获。延迟数据按当前加速度外推并加大噪声，超过 2 秒的直接拒绝。
- **启动与失联**：启动或长时间失联后需要连续两次相容定位才输出。失联后进入 `predicted`，手持最多推算 3 秒，模型误差过大会提前转为 `unavailable`（不显示速度）。
- **惯性辅助（可选）**：默认不对手持加速度积分。仅在手机固定安装并提供车辆前向轴时，才用去重力加速度延长短时推算（最多 6 秒）；手机转动或姿态变化过大会立即停用。
- **出行识别**：以系统运动活动（`CMMotionActivityManager`）为主要证据，用可信的 GNSS 速度做一致性检查，并要求切换确认；静止不单独决定出行方式。识别结果不会反过来改变测速引擎。

`uncertainty` 是模型误差尺度（m/s），尚未标定为统计置信区间。当前参数基于合成场景，真实车载精度还需要真机数据和独立参考速度验证。

详细说明见 [`docs/`](docs)：[算法与参数](docs/algorithm.md) · [调参与回放](docs/tuning.md) · [出行识别](docs/travel-recognition.md)

## 运行

用 Xcode 打开 `Speedometer.xcodeproj`，选择 `Speedometer` scheme，真机运行时在 Signing 中选自己的开发团队。首次启动需允许“精确位置”；出行识别另需“运动与健身”授权（拒绝后仍可测速）。切到后台会暂停采样，回到前台重新确认速度。

## 测试与回放

```sh
swift test                                  # 单元测试
swift run speed-replay --benchmark          # 合成场景基准
swift run speed-replay /abs/path/session.jsonl > estimates.jsonl
```

在 Scheme 的 Run → Arguments 添加 `--record-sensors` 可把传感器数据（不含经纬度）记录到 App 的 Documents，供离线回放。

## 目录

```
Sources/SpeedCore     滤波、校验、出行识别（纯 Swift，可单测）
Sources/SpeedReplay   回放与基准命令行工具
iOS/Speedometer       SwiftUI 界面与传感器服务
Tests/                单元测试
docs/                 算法、调参、识别说明
```
