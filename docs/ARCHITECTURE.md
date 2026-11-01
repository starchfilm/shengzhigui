# 架构说明

## 目录

```text
Sources/
  SoundChannels/
    SoundChannelsApp.swift  菜单栏、总音量和应用控制界面
    AudioModel.swift        界面状态、设置、设备刷新与操作协调
    AudioController.swift   在串行后台队列上管理音频通道
    AudioRoute.swift        单个应用的采集、处理和播放生命周期
    Hardware.swift          Core Audio 设备、进程与系统音量接口
  AudioBridge/
    AudioBridge.c          实时缓冲、音量渐变和基础重采样
    include/AudioBridge.h  Swift 与 C 的接口
Tests/AudioBridgeTests/     音频处理单元测试
Resources/Info.plist        应用标识、显示名称和授权文案
Scripts/build-app.sh        构建、打包和本机临时签名
```

## 音频路径

```text
应用进程 → Core Audio Process Tap → 只包含 Tap 的私有聚合设备
        → C 环形缓冲与音量处理 → AVAudioEngine → 指定输出设备
```

Tap 使用 `mutedWhenTapped`：读取期间替代应用原输出，停止读取后恢复原路径。聚合设备不包含硬件麦克风，避免主动打开耳机麦克风。

切换输出时保留 Tap、聚合设备、缓冲和源音频格式，仅重启播放引擎并设置新设备。混音器将源格式转换为目标硬件格式。切换失败时尝试恢复先前设备；应用进程集合变化时重建整个通道。

## 线程与状态

- 主线程维护 SwiftUI 状态，不直接创建、切换或销毁音频通道。
- `AudioController` 的串行队列负责通道生命周期，向界面传递值类型快照。
- 独立硬件队列枚举应用和设备、读写系统音量及默认输出。
- 实时回调使用 C11 原子变量和单生产者、单消费者环形缓冲，不加锁、不分配内存。
- 应用音量设置延迟合并保存，实时信号只在有声、无声状态发生变化时更新界面。
- 操作使用代次标识，避免过期的启动结果重新开启已关闭的通道。

## 命名和配置

产品显示名称为“声之轨”。为保留本机授权和已有设置，内部 Swift 包、可执行文件和标识仍使用 `SoundChannels`、`com.starchfilm.SoundChannels`。修改这些标识时需要考虑权限和偏好设置迁移。

设置通过 UserDefaults 保存。程序不持久化音频，不包含网络请求。构建缓存、应用产物和本机临时维护脚本均不进入 Git。

## 测试边界

自动测试覆盖 C 音频桥的数学与缓冲行为，不能代替系统权限、硬件路由和真实听感验证。调整通道生命周期或设备切换逻辑后，应在打包后的应用中播放音频，检查切换、恢复、设备断开与退出行为。

切换日志使用 subsystem `com.starchfilm.SoundChannels`、category `Audio`，记录复用采集通道时的播放引擎切换耗时。内部耗时不等于用户听到的断音长度。
