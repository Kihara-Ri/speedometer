# 测速计

原生 iOS 移动测速与出行状态识别，Swift 6 / iOS 17+。核心通过服务回调提供结果，当前 iOS 界面订阅测速模型。无服务器、账户、广告或第三方依赖。

## 打开和运行

打开 `Speedometer.xcodeproj`，选择 `Speedometer` scheme 和 iPhone。真机运行时在 Signing 中选择自己的开发团队。

启动后申请系统定位授权；需要“精确位置”。切到后台停止定位与运动采样，回到前台重新确认速度，避免把后台前的速度带回来。当前版本不声明后台定位能力。

`iOS/Speedometer/SpeedometerService.swift` 提供 `start(recordingTo:)`、`stop()`、`suspend()`、`resume()`，通过 `onEstimate`、`onStatus`、`onTravel` 输出。默认是手持测速模式；出行方式识别与手机安装状态分别处理。

## 算法

- 使用 Core Location 的速度和精度，不用相邻经纬度差分放大位置误差。
- 三状态卡尔曼滤波：速度、纵向加速度、加速度偏置。Joseph 协方差更新；巡航使用较小过程噪声，合理的明显加减速提高过程噪声。
- 检查速度/精度有效性、时间戳、观测年龄、物理加减速与标准化创新。单次大跳点不刷新可信速度；持续相容的新观测允许重新捕获。
- 启动和预测超时之后，需要两次相容定位才输出速度。失联后是 `predicted`，手持最多预测 3 秒；模型误差尺度超过 8 m/s 时提前返回 `unavailable` 和 `speed == nil`。
- 安静的 IMU 不代表车辆静止；匀速电车不会因此被归零。
- 默认不对自由手持加速度积分。**固定安装**时才可传入车辆前向轴，例如手机顶端沿车辆前进方向：`SpeedometerService(mountAxis: try MountAxis(x: 0, y: 1, z: 0))`。输入是设备坐标中的车辆前向方向，必须由实际安装保证。去重力加速度以标准重力换算到 m/s²。
- 固定安装需连续采样至少 8 秒、偏置方差收敛才允许延长失联预测，最多 6 秒。运动数据间断超过 0.3 秒重新累计；角速度超过 0.25 rad/s 或相对姿态累计变化超过 10° 立即禁用惯性辅助，需要重新确认安装并重启服务。车辆转弯也可能触发保守禁用。

`uncertainty` 的单位是 m/s，是模型误差尺度，尚未经真实设备校准为统计置信区间。所有时间都是同一单调时钟上的秒；位置回调保留测量时间和接收时间，延迟超过 2 秒的数据拒绝，较短延迟按当前加速度近似外推并增加观测噪声。系统时钟跳变会清空融合状态。

自动识别乘车 / 自主出行（步行、跑步、自行车），证据不足时保留 unknown。使用系统运动活动、可信速度一致性与切换确认；仅识别为乘车不会开启惯性积分。需要“运动与健身”授权，拒绝后仍可定位测速。

详细说明：

- [乘车与自主出行识别](docs/travel-recognition.md)：分组、置信度、切换时间、静止歧义、权限与回放。
- [测速原理、算法与完整参数](docs/algorithm.md)：状态方程、F/Q/H/R、Joseph 更新、异常与重捕获、固定安装约束、预测失效条件和源码位置。
- [调参、回放与真机实测手册](docs/tuning.md)：合成结果及局限、记录采集、故障注入、评估指标、参数试验范围和复核流程。

目前参数基于合成场景，真实车载调参需要录制数据和独立参考速度。

## 测试与回放

```sh
swift test
swift run speed-replay --benchmark
swift run speed-replay /absolute/path/session.jsonl > estimates.jsonl
# 仅对固定安装、包含已投影 motion 的记录：
swift run speed-replay /absolute/path/mounted-session.jsonl --mounted
```

在 Xcode Scheme 的 Run → Arguments 添加 `--record-sensors`，会将本地记录写入 App 的 Documents，能通过 Finder 文件共享或 Xcode 下载容器提取。默认不记录。包括接收时间、定位测量时间、原始速度/精度、原始三轴加速度/重力/角速度/四元数、可选前向加速度、时钟 tick 和会话 reset；不记录经纬度。日志文件使用设备数据保护，写入失败通过 `recordingFailed` 状态报告。记录可能较大，采集完成后移出或删除文件。

JSONL 每行示例：

```json
{"receivedAt":100,"speed":{"timestamp":100,"speed":20,"speedAccuracy":0.5,"horizontalAccuracy":5}}
{"receivedAt":101,"speed":{"timestamp":101,"speed":20.2,"speedAccuracy":0.5,"horizontalAccuracy":5}}
{"receivedAt":103}
{"receivedAt":105}
```

接收时间必须递增或相等；测量时间可以乱序，以重现核心的拒绝路径。无观测的行表示时钟推进。非法 JSON 或事件歧义会明确退出，不跳过损坏记录。NaN/Infinity 以字符串保留并在回放中还原，测试拒绝逻辑。

`docs/benchmark.json` 由 `--benchmark` 生成，固定随机种子，包含匀速、加速/紧急制动、高速列车、GNSS 跳点、手持/固定安装的隧道中断。误差全部是 m/s：

- `rawRMSE`：原始观测在定位时刻的误差。
- `estimatedAtFixRMSE`：滤波结果在可用的定位时刻的误差。
- `estimatedRMSE`：每 0.1 秒输出可用时的误差；包括定位间的预测，因此不能与仅在定位时刻统计的原始误差直接等同。
- `heldSpeedRMSEOnAvailableSamples`：同一组可用时刻简单保持上次原始速度的误差。
- `unavailableSamples`：主动停止估计的次数；不可用时刻不算作零误差。

这些是可复现的合成验收，不代表真实电车、汽车或摩托车的精度认证。真机道路/隧道采集及独立参考速度对照尚待完成。

## 构建

```sh
xcodebuild -project Speedometer.xcodeproj -scheme Speedometer \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Speedometer.xcodeproj -scheme Speedometer \
  -sdk iphoneos -destination 'generic/platform=iOS' -configuration Release \
  -derivedDataPath .build/device CODE_SIGNING_ALLOWED=NO build
```

## 本次验证记录

28 项 Swift 测试通过；iOS 模拟器 Debug 和设备 SDK Release 均构建通过。iOS 27 模拟器使用 Scene 生命周期启动，记录并成功回放 248 个事件。模拟器注入了 20 m/s，但 `speedAccuracy == -1`，42 次速度观测均按合同拒绝，未冒充有效测速。汇总见 `docs/simulator-smoke.json`。设备 SDK 构建不等于已在物理 iPhone 上验证。

2026-10-18 新增自动出行识别：完整 51 项测试通过，原有测速基准不变；更新版已在 iPhone 12 mini 安装启动。首次使用需系统“运动与健身”授权，真实乘车/下车/骑行识别率尚待行程验证。
