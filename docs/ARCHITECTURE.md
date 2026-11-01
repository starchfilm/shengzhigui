# 架构说明

## 目录

```text
Sources/
  SoundChannels/
    SoundChannelsApp.swift  菜单栏、总音量和应用控制界面
    VolumeSlider.swift      保持轨道颜色的原生音量滑条
    AudioModel.swift        界面状态、设置、设备刷新与操作协调
    AudioController.swift   在串行后台队列上管理音频通道
    AudioRoute.swift        单个应用的采集、处理和播放生命周期
    DuckingProtection.swift 通话压低系数的兼容处理
    Hardware.swift          Core Audio 设备、进程与系统音量接口
  AudioBridge/
    AudioBridge.c          实时缓冲、音量渐变和带限重采样
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

C 音频桥使用 64 抽头、1024 相位的 Blackman 窗 sinc 插值；在建立通道时预计算系数，实时回调不分配内存。相邻相位系数插值以降低相位量化误差；降采样时收窄截止频率。同采样率且无分数相位时走直接复制路径，保留相同的固定滤波延迟。读指针保留插值需要的历史样本，避免生产者提前覆盖。缓冲补偿阈值按实际回调长度缩放，不再把正常的 480 帧回调误判为饥饿。

## 线程与状态

- 主线程维护 SwiftUI 状态，不直接创建、切换或销毁音频通道。
- `AudioController` 的串行队列负责通道生命周期，向界面传递值类型快照。
- 独立硬件队列枚举应用和设备、读写系统音量及默认输出。
- 实时回调使用 C11 原子变量和单生产者、单消费者环形缓冲，不加锁、不分配内存。
- 应用音量设置延迟合并保存；通道状态以 1 秒间隔获取，界面不依据瞬时音频峰值切换文字。
- 操作使用代次标识，避免过期的启动结果重新开启已关闭的通道。

## 命名和配置

产品显示名称为“声之轨”。为保留本机授权和已有设置，内部 Swift 包、可执行文件和标识仍使用 `SoundChannels`、`com.starchfilm.SoundChannels`。修改这些标识时需要考虑权限和偏好设置迁移。

设置通过 UserDefaults 保存。程序不持久化音频，不包含网络请求。构建缓存、应用产物和本机临时维护脚本均不进入 Git。

## 测试边界

### 通话音量保护

Process Tap 与重新播放本身不能绕开设备端的通话压低。开发机日志中，微信激活语音处理后，其他客户端的压低系数为 0.177828。`DuckingProtection` 在音频管理队列上对受控播放设备写入 unity（1.0）系数，系统随后将本应用客户端的系数报告为 1.0。

`duck` 是未公开的属性。调用前检查属性存在、可写且长度为 16 字节；不符合时直接返回错误，不修改设备。写入发生在实时回调之外，维持周期为 300 毫秒；没有受控通道时停止维持。它不修改扬声器总音量、不提高样本增益，不尝试改变微信内部的语音处理设置。未开启控制的其他应用仍可能被系统压低。

开关的轨道和滑块位置由显式 SwiftUI 样式绘制，不显示重复的开关文字，避免非活动窗口的系统开关灰化导致误读；保留原生 Toggle 的辅助功能语义。音量滑条使用 NSSlider 保留拖动、键盘和辅助功能，仅通过自定义 NSSliderCell 绘制保持蓝色的进度轨道。

参考调查：[Apple 语音处理与其他音频压低](https://developer.apple.com/videos/play/wwdc2023/10235/)、[Unduck Pro 的设备属性调查](https://github.com/MrRockySL/Unduck-Pro)。本仓库的兼容层独立实现，并以本机 Core Audio 属性和日志验证。

自动测试覆盖 C 音频桥的数学与缓冲行为，不能代替系统权限、硬件路由和真实听感验证。调整通道生命周期或设备切换逻辑后，应在打包后的应用中播放音频，检查切换、恢复、设备断开与退出行为。

切换日志使用 subsystem `com.starchfilm.SoundChannels`、category `Audio`，记录复用采集通道时的播放引擎切换耗时。内部耗时不等于用户听到的断音长度。
