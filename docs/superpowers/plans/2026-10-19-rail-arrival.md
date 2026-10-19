# 轨道交通到站推测实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 测速记录期间，在疑似轨道交通基本停稳后提示用户确认到站，并保存可回放反馈。

**Architecture:** SpeedCore 增加独立的到站状态机，在线服务与离线回放共用。候选与反馈以可选 JSONL 字段持久化，SwiftUI 顶部卡片消费同一候选状态。

**Tech Stack:** Swift 6、Swift Testing、SwiftUI、Core Motion、Core Location；不增加依赖。

**Spec:** [轨道交通到站推测](../specs/2026-10-19-rail-arrival-design.md)

## Global Constraints

- 已经基本停稳后才提示；一次停车只提示一次。
- 无定位不补零，第一版不对纯惯性片段推断停稳。
- 预测与用户反馈分开保存，未回应不能算否认。
- 不改变测速、固定安装积分及里程算法。
- 保留当前工作区已有改动，不自动提交或发布。

## Review Focus

- 连续时间：旧定位、倒序、长间隔不能累计停稳证据。
- 混淆：道路重复停车可能类似轨道运行，输出保持推测且需真实负样本验证。
- 手机拿放：旋转导致惯性证据中断，不能当车辆制动。
- 候选生命周期：恢复行驶或停止记录后不能接受旧卡片反馈。
- 标记时间：确认按钮晚点按下不能把到站时刻移动到点击时刻。

### Task 1：可回放识别与反馈

**Files:** 创建 `Sources/SpeedCore/RailArrivalRecognizer.swift`、`Tests/SpeedCoreTests/RailArrivalTests.swift`；修改 `Sources/SpeedCore/Replay.swift`。

**Interfaces:** `RailArrivalRecognizer.consume(_ event: ReplayEvent) -> RailArrivalUpdate`；更新包含当前轨道上下文、候选与本次结束的候选。候选包括 ID、版本、证据时间范围、停稳时间和特征摘要。反馈包括候选 ID、回答和响应时间。原始预测使用独立字段，回放输入不将旧预测当新观测。

- [x] 写受控速度序列测试，覆盖完整重复运行后停稳、尚在制动、降速后恢复、只有一次停车、短停、缺失速度、手机转动、步行、骑行、时间异常。
- [x] 运行 `swift test --filter RailArrivalTests`，确认失败来源是新增行为尚未实现。
- [x] 实现状态机：连续可信速度建立运行与制动过程，运动证据剔除拿放片段，重复周期建立疑似轨道上下文；使用具名配置记录初始实验阈值，不将其描述成实测参数。
- [x] 增加确认、否认、超时、恢复行驶、会话重置和重复反馈测试；实现单次停车去重、候选过期及反馈关联。
- [x] 接入 SpeedReplay，与在线服务使用相同输入顺序和有效性规则；加入旧 JSONL 解码与新事件往返回放测试。
- [x] 运行 `swift test`，确认原有测速、里程与记录测试通过。

### Task 2：在线记录、顶部卡片与验收

**Files:** 修改 `iOS/Speedometer/SpeedometerService.swift`、`SpeedometerModel.swift`、`SpeedometerView.swift`、`Sources/SpeedCore/SessionReport.swift`、`Recording.swift`、`Speedometer.xcodeproj/project.pbxproj`；更新 `docs/travel-recognition.md`、`docs/train-recording.md` 与 `README.md`。

**Interfaces:** 服务输出当前候选；`respondToArrival(id:answer:)` 先校验候选仍有效，再记录关联反馈。确认到站标记保留候选时刻；RecordingMarker 使用可选事件时刻，旧日志仍按 receipt time 解析。

- [x] 添加标记时刻与反馈持久化测试，先验证失败，再实现可选字段和报告解析。
- [x] 在线服务接入同一识别器，按顺序写入候选、结束原因和反馈；结束记录前保存未确认状态。
- [x] 模型暴露当前候选与反馈动作，顶部覆盖卡片从上方出现，提供两个按钮及可访问性标签，不挤压底部控制区。
- [x] 在 Xcode target 中注册新核心文件；构建 iOS Simulator 应用。
- [ ] 使用受控回放检查停稳提示、两个反馈动作、重复点击、恢复行驶收起、小屏布局和日志中的候选关联；测试辅助输入与正式传感器入口分开。
- [x] 更新算法初始参数、验证结果与剩余风险。实测仍需列车、道路交通、车厢拿放与地下无定位的独立标签记录。

建议由当前会话直接执行，按上述两项依次验证。

## 实施结果与边界

2026-10-19：76 项 Swift 测试、8 项 Python 测试、模拟器 Debug 构建通过；模拟器真实 Model/Service/Journal 的四项保存流程检查通过。独立只读审查发现匀速被计入制动的问题，新增回归用例先复现再修复；非停稳状态匀速超过 2 秒即中断制动。候选证据起点包含建立轨道上下文的首个完整运行周期。另一个回归测试复现了跨行程递增编号导致单份日志回放无法关联反馈的问题，已改为按停稳时刻生成确定性 ID；第二次行程独立回放可保留其否认反馈。

实施核对发现当前主页面已移除手动标记入口，因此保留自动采集界面和旧标记兼容，不恢复旧入口；漏检依靠独立现场时刻记录核对。工作在 codex/rail-arrival 分支，保留开始时的未提交改动；没有提交或发布。

UI 测试宿主已编译，支持受控回放、小宽度/大字号布局检查和程序调用卡片所绑定回放回调的保存检查；这轮未完成宿主验收：现有模拟器被系统授权框覆盖，ImageRenderer 的 GPU 导出等待 Metal 编译，专用小屏模拟器首次启动又持续停在系统数据迁移。已改用 UIHostingController 布局检查以便后续复跑，但不能声称该布局与按钮持久化检查通过。桌面工具未能访问 Simulator，未完成真实点击自动化。真实列车与道路混淆仍需独立标签实测。
