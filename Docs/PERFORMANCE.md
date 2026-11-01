# 性能检测与优化（2026-11-01）

## 范围与方法

审查了应用业务代码的书架 / 书单 / 详情、EPUB 与 TXT 导入、Readium 阅读与语音回调、书内 / 跨书全文搜索、在线书目 / 详情 / 封面、标注导出、进度与统计持久化。未修改 Readium 或其他第三方库内部实现，也未改变阅读器布局、翻页方式或存储格式。

以下是同一台 Mac、同一个 iPhone 18 Pro QA 模拟器、Xcode 27.2 Debug 构建的 CPU 基准，取三次中位数。基线为 `caaf612` 的实现加检测入口；优化后使用相同数据规模与校验结果。不是 SwiftUI 整页绘制耗时，也不是设备帧率或电量结论。测量时未挂 Instruments，未同时构建其他配置。

| 工作负载 | 优化前 | 优化后 | 耗时下降 |
| --- | ---: | ---: | ---: |
| 1000 本书，排序与 30 个可见行的末尾判断 | 19.426 ms | 0.467 ms | 97.6% |
| 1000 条划线 / 笔记导出 | 27.144 ms | 15.511 ms | 42.9% |
| 12000 条历史记录，100 次计时更新 | 109.290 ms | 0.797 ms | 99.3% |

附加检测：

- 2048×3072 原图缩略到 160×240，解码图像占用 153600 字节；两个同时发起的相同请求只加载一次，连续 30 次缓存命中约 0.196 ms，没有新增解码。此处只统计像素缓冲，不代表进程总内存。
- 50000 段 TXT 转换约 669.2 ms；同时在主线程每 10 ms 检测心跳，观测到 60 次、最大间隔 11.1 ms。此检查验证主线程可运行，不是屏幕流畅度测量。
- 1000 次未变化的 TTS 停止状态回调，未发布任何界面更新；播放逐词回调同样只在播放状态实际变化时更新 `isSpeaking`。
- 累积统计与逐条汇总一致，重启后汇总一致；缺失封面安全回退。
- 在途统计快照与修改目标、匿名化、清空同时发生时，不覆盖较新的提交；实际等待 15 秒的自动保存无需手动刷盘即可在新 Store 中读回。

功能回归覆盖旧索引、混合导入、进度合并、书单、导出、删除恢复与损坏文件保护，另有真实 EPUB 中文字体切换、TXT 三种编码、全文匹配 / 定位和实际 ReaderView 前台计时。并行构建时，固定 12 秒的阅读计时检测曾仅记录接近零的时长而失败；停止构建后独立复跑记录 9.86 秒阅读、零听书并通过。初次失败可能与载入窗口及环境负载有关，未额外分解该次载入耗时，也未将其当作有效性能样本。

不同复跑存在 CPU 调频和缓存波动：例如上一轮无采样复跑的三个中位数为 0.986 / 17.436 / 0.771 ms；表中列的是最终构建的复跑结果，不选择最小单次样本。

## 已实施

1. 书架每次生成视图时只准备一次筛选 / 排序快照，行内不再重新排序整个书库；书单数量按书籍单次聚合。
2. 标注排序预先解析一次 locator JSON，不在比较器里重复解码。
3. 共用封面管线：合并相同在途请求、ImageIO 后台缩略 / 预解码、按展示尺寸选择分辨率；NSCache 预算 24 MiB / 96 项，由系统决定回收。一个视图取消不影响其他使用者，所有使用者取消后中止底层请求；已取消的视图不新建任务。行封面不再在主线程检查文件是否存在。
4. TXT 转换、文件内容指纹、导入文件复制 / 封面写入、在线搜索 / HTML 解析明确使用 `@concurrent`。TXT 章节正则只编译一次，长行只检查前 81 个字符是否可能为标题。
5. 新导入 EPUB 使用 Readium 的 `coverFitting`，封面限定 600×600；PNG 编码移到后台。已有原书与封面不批量重写。
6. 朗读逐词 / 视口 / 进度回调不发布未变化的值；进度采用预计算的章节偏移与资源索引，保留 URL 等价判断的兼容回退。
7. 阅读统计原位更新目标记录，维护每日 / 单本 / 全部聚合，不再每次复制和扫描完整历史；图表使用每日聚合。
8. 自动保存的书架 / 统计 JSON 编码移到后台；原子提交仍串行进行。新修改会取消旧书架任务；统计用修改版本和持久化代次保护，旧快照不能覆盖新目标、匿名化或清空。退出 / 后台仍显式刷盘，用户主动编辑与删除仍保留原有事务语义。
9. 设置页面仅在出现 / 回到前台时刷新系统音色，不随每次滑块值变化重新枚举和排序全部音色。

## Instruments 与复测

加入本地 `OSSignposter`：`ReaderLoad`、`BookImport`、`TXTConvert`、`CoverLoad`、`FullTextSearch`、`LibraryEncode`、`ActivityEncode` 与同步保存区间。无遥测、无联网发送。

采集了 QA 模拟器 35 秒 Time Profiler：984 个 CPU 样本中，627 个包含 TXTImporter 的样本均在工作线程，30 个包含 CoverImagePipeline 的样本也均在非主线程。合成测试的数据生成、笔记导出和 UIKit 原图创建仍在主线程，因此不要把整个 QA 进程主线程占比解读为实际阅读页面负载。xctrace 提示一张辅助表缺少输入源，但 CPU 调用栈表已成功导出，以上结论来自有效样本，不依赖该辅助表。

Debug 模拟器启动参数：

```sh
xcrun simctl launch DEVICE_ID com.Voltline.BookShelf --performance-regression
```

结果在测试 App 的 Documents/performance-results.txt；使用唯一缓存目录，不访问正式书架。必须等最终 PASS；自动检查点验证需要等待 15 秒，整轮约 20 秒。加 `--performance-profile` 会在开始前多留出采样附加时间。

```sh
xcrun xctrace record --template 'Time Profiler' --device DEVICE_ID \
  --attach BookShelf --time-limit 35s --output /tmp/bookshelf-performance.trace
```

自定义采样模板可按 subsystem `com.Voltline.BookShelf`、category `Performance` 开启上述区间；默认 Time Profiler 的 Points of Interest 不一定包含自定义分类。

## 保留的边界

Debug / Release 的 iOS Simulator 构建（arm64 / x86_64）、性能专项、书库、字体、TXT、全文搜索回归均通过；统计页面和实际阅读页面已检查截图。没有新增并发隔离告警，保留已有的 StringSearchService 弃用提示及未依赖 AppIntents 的元数据提示。

- 启动时仍同步读取并校验本地索引 / 统计；显式退出刷盘、笔记编辑、删除事务仍同步编码与提交。超大书库下这些路径仍值得通过真机采样继续评估，未为追求异步而削弱损坏文件保护和删除恢复。
- 全文搜索仍由 Readium 驱动，使用已有单本 / 全局上限和取消隔离，不引入无界并行扫描或常驻全文副本。未改变此前为中文混排稳定性保留的 StringSearchService 兼容路径。
- 网络耗时依赖站点，不把本地 CPU 优化推算成请求加速；在线请求有原有超时与取消保护。
- 尚未测量真机 Release 的滚动帧率、长时间锁屏听书耗电、内存峰值和泄漏；这些需要在实际设备用 Time Profiler、Allocations、Leaks、Energy Log 继续验证。

并发语义依据 [Swift 官方并发诊断文档](https://docs.swift.org/latest/documentation/diagnostics/nonisolated-nonsending-by-default/)；区间采样依据 [Apple Recording Performance Data](https://developer.apple.com/documentation/os/recording-performance-data)。
