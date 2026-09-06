# 本地构建与回归

需要支持项目部署目标的 Xcode。测试文件不参与应用构建，不使用真实 AI 服务、真实钥匙串或用户 PDF。所有 PDF、图片及网络响应均为合成或模拟数据。

```sh
bash scripts/verify-build.sh local-debug Debug
bash scripts/run-pdfview-regression.sh
SIMPLEVIEW_SANITIZER=thread python3 scripts/run-regressions.py
bash scripts/verify-build.sh local-release Release
```

- `run-pdfview-regression.sh` 链接实际 Debug 应用，检查视图释放、原生模糊墨迹层移除、多倍率矢量精度、标注图标、隐藏时保存、独立进程重开、草稿自动保存/撤销及外部更新冲突。
- `run-regressions.py` 检查保存失败保护、旧格式迁移、文件监控、缓存预算、取消与会话隔离、模型路由、模拟钥匙串和离线文本渲染。
- 构建产物与日志写入系统临时目录，不纳入 Git。测试脚本打印具体位置，失败时可据此诊断。

体积回归样本为十页空白 PDF，加一百条带笔记的标注和一万个手绘采样点。去除重复文本坐标后，文件从 1,105,693 字节降至 546,326 字节，重复保存大小不再增加。回归同时确认全部采样点保留，以及提交前后、重开后在 1×、4×、8× 下的像素一致。此样本用于检测存储膨胀，不代表所有 PDF 的固定增长量。
