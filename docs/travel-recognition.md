# 乘车与自主出行识别

2026-10-19 新增独立的[轨道交通到站推测与反馈](rail-arrival.md)：运行周期重复、持续制动和可靠低速支持下才在停稳后提示。原有 vehicle / independent / unknown 分类口径保持不变，疑似轨道交通不等于已证明交通工具类型。

更新日期：2026-10-18。实现见 [TravelModeRecognizer.swift](../Sources/SpeedCore/TravelModeRecognizer.swift)，真机接入见 [SpeedometerService.swift](../iOS/Speedometer/SpeedometerService.swift)。

## 1. 分类口径

按本次确认的需求：

| 输出 mode | 含义 |
|---|---|
| `vehicle` | 系统活动证据支持乘坐机动车辆；不细分电车、汽车或摩托车 |
| `independent` | 不依赖上述交通工具：步行、跑步、自行车；自行车按用户要求归这一组 |
| `unknown` | 正在确认、证据矛盾、权限/硬件不可用，或无法区分 |

静止不能单独确定出行方式：站在站台和坐在停着的车里都可能静止。因此只在已有出行上下文时短暂保留其分类，不凭“安静”推出自主出行，也不强制把速度归零。

这里的出行方式与 `SensorMode.handheld/mounted` 是两条独立轴。乘车也可能手持；自行车上也可以有支架。**识别成 vehicle 不会自动启用固定安装积分，不会延长测速引擎的预测时限。**

## 2. 使用什么证据

主要输入来自 `CMMotionActivityManager`，读取 automotive、walking、running、cycling、stationary、unknown 和系统定性的 low/medium/high confidence。已有去重力加速度、角速度仍服务于测速/固定安装检查；新分类器没有用几条原始 IMU 阈值冒充一个训练好的交通识别模型。

系统活动标志可以同时为 true。例如 automotive 与 stationary 同时为 true，可以表示等红灯；不能用 stationary 覆盖 automotive。automotive 与 walking/running/cycling 同时为 true，则本次分类返回未知，原因 `conflictingActivity`。

GNSS 只作为一致性检查。仅接受测速引擎已经接受、且分类器再次校验通过的位置速度：

- 有限、0…140 m/s；速度精度在 0…1.5 m/s，水平精度在 0…50 m。
- 位置年龄不超过 1.5 秒，未来容差 0.05 秒，时间顺序有效。
- 不输入模型/惯性预测结果，避免把自己的预测反过来当识别证据。

高速度本身不会把模式设为 vehicle，因为骑行也可能很快。对于非骑行的人体活动，计算 `speed - 2*max(0.35, speedAccuracy)`；若其仍高于步行 4.5 m/s 或跑步 12 m/s，返回 `speedConflict`。这些是保守一致性门限，不是步行/跑步的普遍生理上界或已校准的统计检验。

## 3. 活动事件与确认时间

Apple 活动回调是状态变化事件：先交付当前活动，再在活动变化时通知；不是每秒重复一条。分类器因此保留最新活动，直到新事件、权限变化或生命周期 reset，而不会因为几秒没新回调就认定活动失效。

`ActivityObservation.timestamp` 是收到活动回调的 uptime；原始 `startDate` 另存为 `startedAtWallTime`，只供诊断，不直接参加确认。系统报告的活动可能从很早以前就开始，不能用这个历史开始时间跳过本次会话的确认。

分类器的 `advance(to:)` 会推进确认状态，它与测速引擎无副作用的 `estimate(at:)` 不同。服务在每次输入事件和 tick 推进分类器，离线回放也使用相同顺序。

| 参数 | 当前值 | 含义 |
|---|---|---|
| 高置信活动首次确认/一般切换 | 2 秒 | 单次短暂活动不立即切换 |
| 中置信活动首次确认/一般切换 | 4 秒 | 比高置信等待更久 |
| 乘车切换到自主出行 | 5 秒 | 对下车判断更保守，包含骑行切换 |
| 低置信活动 | 最多沿用旧分类 8 秒 | 始终标 low；之后未知，不建立新分类 |
| 只有 stationary 时 | 最多沿用旧分类 120 秒 | 从该静止活动事件的接收时刻计算，标 medium；无旧分类则未知 |
| 乘车后出现走/跑、却没有新鲜可信速度 | 最多暂留 vehicle 30 秒 | 标 low、`exitUnconfirmed`；之后未知，不自动判已下车 |
| 活动输入最大传递年龄 | 1 秒 | 按回调 receipt timestamp 校验，不按原始 startDate |
| 活动未来容差 | 0.05 秒 | 大于容差、重复、过期或倒序输入拒绝 |

低置信/未知/冲突活动不会生成新的肯定分类。系统肯定活动一直未改变时，确认后的类别会持续保留；这依赖系统流仍在运行，服务停止、进入后台或权限被撤销时会清空。

“下车”有额外约束：已确认 vehicle 后，仅出现 walking/running 还不足够，因为乘客可能在车厢内走动。需要新鲜且不矛盾的定位速度，才开始/继续这次切换；无 GPS 或存在速度矛盾时，清空该次切换的确认起点。自行车不受步行/跑步速度门限约束，但仍需切换等待。

静止保留只代表上下文推断，不能证明人还在车里。乘客拿着手机在车厢内长时间走动、又恰好收到看似步行速度的错误定位，仍可能误判；当前没有路线、上下车事件或实测训练模型可以完全解决这个歧义。

## 4. 输出接口与权限

`SpeedometerService.onTravel` 输出 `TravelEstimate`，`SpeedometerModel.travel` 保留最新值。未修改现有界面布局。结果包含：

| 字段 | 说明 |
|---|---|
| timestamp | 本次分类输出时刻，uptime 秒 |
| mode | vehicle / independent / unknown |
| confidence | low / medium / high；定性标签，不是百分比或校准概率 |
| reason | activity、confirming、speedConflict、exitUnconfirmed、stationaryContext 等原因 |
| source | waiting / available / denied / restricted / unavailable / stopped |
| pendingMode | 等待切换确认的目标，可为空 |
| stationary / cycling | 最新系统活动对应标志，供消费者解释 |

首次活动识别会使用系统“运动与健身”授权。拒绝或硬件不支持时输出 unknown 和原因，定位测速仍能继续。服务约每 0.2 秒检查授权状态；系统活动 nil 回调按 unknown 处理。切后台不主动停止活动流或重建状态；显式停止再开始时才重建。活动回调带会话 generation 检查，避免上一会话的延迟回调进入新会话。

当前运动活动流随定位测速服务一同开始：没有定位授权或精确位置时，服务不会单独启动活动识别。它不是后台出行追踪器。电车/摩托车的实际识别效果依赖设备和系统活动分类，不能把 automotive API 的存在当成所有场景已验证。

## 5. 记录与回放

原有 `--record-sensors` 记录开关继续有效。新增两类单独事件：

```json
{"receivedAt":100,"activitySource":"available"}
{"receivedAt":100.1,"activity":{"timestamp":100.1,"confidence":"high","automotive":true,"walking":false,"running":false,"cycling":false,"stationary":false,"unknown":false}}
{"receivedAt":102.1}
```

回放：

```sh
cd /Users/kiharari/DEV/测速计
swift run speed-replay /absolute/path/session.jsonl > /tmp/travel-estimates.jsonl
```

每行输出保留原来的 result/estimate，新增 `travel`。上述例子最后一行会得到 vehicle，测速 estimate 仍为 unavailable，因为没有任何速度观测。识别不能凭空制造速度。

每个事件最多含一项主动作：speed、motion、activity、activitySource、reset=true、resetSpeedOnly=true。rawMotion 可以作为附带原始数据。旧日志没有活动输入，仍可读取，travel 为 unknown。

`reset=true` 是会话重置，清空测速和出行识别。墙上时钟跳变改记 `resetSpeedOnly=true`：只重置测速，保留没有变化的系统活动状态。由于活动管理器不重复发送同一状态，不能把一次定位时钟重置误作活动流重启。

日志中的 confidence 和所有活动布尔字段均保存原值。回放重建识别逻辑，不重新运行 Apple 的原始传感器分类器。无需在线服务或上传原始活动。

## 6. 验证与后续调参

本次完整 Swift 套件 51 项通过（原有 28 项，新增识别 18 项与回放 5 项）；模拟器 Debug 和签名设备 Release 构建通过。原有六组测速基准与保存结果完全一致。更新版已在连接的 iPhone 12 mini 上安装并启动；这不等于已完成真实交通场景识别率验证。

新增的受控测试覆盖：步行/跑步/自行车分组、启动等待、状态保持、红灯双标志、单独静止未知、上下文超时、低置信、冲突标志、车厢走动、速度矛盾、下车等待不累计矛盾时段、无效时间、权限/生命周期、日志回放及出行识别不打开惯性积分。

```sh
swift test
```

调参需要带独立行程标签的真机记录，至少包括步行→乘车→停车→下车→步行、自行车、跑步、列车车厢走动和隧道。统计每个类别的误判/漏判、unknown 时间比例、上车/下车识别延迟，以及权限拒绝下的退化表现。未完成这些实测前，不承诺汽车、摩托车、电车的具体识别准确率。

API 依据：[CMMotionActivity](https://developer.apple.com/documentation/coremotion/cmmotionactivity) 与 [startActivityUpdates](https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager/startactivityupdates(to:withhandler:))；其标志可同时成立、首次交付当前状态及之后按变化回调的行为，也见本机 SDK 的 `CMMotionActivity.h` 与 `CMMotionActivityManager.h`。
