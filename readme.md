# 开局托儿所 Bench

微信小游戏“开局托儿所”的 macOS 自动挑战程序与实验记录。通过游戏窗口截图、Vision OCR 和系统鼠标事件完成操作：先搜索整局消除路径，再逐步执行、核对棋盘并记录结算。

**最高已验证实测：159 分；尚未取得实测 160 分。** [159 分结算截图](results/session-20261110-005453/round-113/settlement.png)对应74次消除。这张棋盘数字总和为748，每次消除总和为10，因此至少留一格，159已达到该棋盘的理论上限。

## 环境与要求

| 项目 | 已验证环境 / 要求 |
| --- | --- |
| 系统 | macOS 26.6，Apple Silicon arm64；其他系统版本与 Intel Mac 尚未验证 |
| 编译器 | Apple Swift 6.3.3、Apple Clang 21.0.0，C++17 |
| SDK | 本机已验证 macOS 15.4 SDK；可通过 `GAME_ASSISTANT_SDK` 指定 |
| 脚本 | Bash、Ruby 2.6.10 及其标准库、Git；不依赖第三方 Ruby 包 |
| 图形框架 | macOS 自带 Cocoa、CoreGraphics、Vision、CryptoKit |
| 游戏 | 已登录的微信桌面客户端，手动打开“开局托儿所”小程序 |
| 权限 | 给运行命令的终端或宿主应用开启“屏幕与系统音频录制”和“辅助功能”权限 |
| 运行状态 | 游戏窗口在前台，运行时保持窗口位置、显示器和尺寸稳定，避免同时移动鼠标 |

不需要 Python、虚拟环境、Node.js、GPU 或额外模型。默认最多使用8个搜索线程，按硬件并发能力调整。归档资料约456 MB，主要为游戏窗口截图。

安装编译工具可使用 `xcode-select --install`。构建脚本优先使用指定的 SDK，其次寻找当前 SDK 同目录下的15.4版本，最后使用活动 SDK；遇到 SDK/编译器不兼容时，应选择本机兼容版本。

## 克隆、编译和自测

```bash
git clone git@github.com:shiyt23/kaiju-tuoersuo-bench.git
cd kaiju-tuoersuo-bench
./scripts/build.sh
./scripts/test.sh
```

也可用 HTTPS 克隆。指定 SDK 的例子：

```bash
GAME_ASSISTANT_SDK="$(xcrun --sdk macosx --show-sdk-path)" ./scripts/build.sh
```

编译产物为根目录的 `GameAssistant` 和 `Solver`，不纳入 Git。`test.sh` 重新构建并执行数值分组、路径、检查点、OCR、界面识别与图像核验测试，使用仓库中的样本，不发送游戏鼠标操作。

## 启动连续挑战

在微信中手动打开游戏，停在主界面或结算页，然后运行：

```bash
./GameAssistant status

# 连续40分钟，每局执行搜索找到的最高分路径
./scripts/run-session.sh 40 score

# 专门冲击160分：筛选棋盘，最多搜索60秒，只执行完整清空路径
./scripts/run-session.sh 40 fullclear
```

两个命令是不同运行方式，选择其中一个执行。新会话写入 `runs/session-时间戳/`，也可传入第三个参数指定一个尚不存在的目录。到截止时间后会处理完当前局，再退出。

| 模式 | 搜索预算 | 行为 |
| --- | ---: | --- |
| `score` | 32秒 | 目标150，仍执行预算内找到的最佳路径，即使分数低于目标 |
| `fullclear` | 最多60秒 | 数学必要条件失败则重开；未搜到满分路径时保存最佳计划并重开 |

配置模板见 [score.json](configs/score.json) 和 [fullclear.json](configs/fullclear.json)。运行期间修改会话目录的 `config.json`，下一局生效。通过满分必要条件并不保证可清空；“预算内未找到”和“已证明无法满分”会分别记录。

无限挑战到期时，程序会按游戏界面观看3次广告。每段至少等待30秒，并确认“已获得奖励”和右上角“关闭”后关闭，再从主界面倒计时核对续期。未知界面会保存证据并停止相应流程。

在会话目录创建 `DRAIN` 文件，可在当前局处理完后退出；创建 `STOP` 文件可尽快停止，包括当前操作。`HOLD` 用于正常结算页的局间暂停，不适用于快速重开循环。也可以在启动终端按 Ctrl+C。

```bash
touch runs/你的会话目录/DRAIN
ruby scripts/report.rb runs/你的会话目录
ruby scripts/audit.rb runs/你的会话目录
```

## 单局、离线搜索和恢复

单局模式不会替你点击“开始游戏”。手动开始，等数字落位后立即运行：

```bash
./GameAssistant play --target 150 --best-effort --search-seconds 32 \
  --strategy portfolio8 --seed 7 --output runs/my-round
```

搜索预算默认32秒、上限60秒；游戏自身也在计时。鼠标执行还需要约40～45秒，具体取决于步数、动画和识别。`--best-effort` 表示执行当前最佳路径；不加时，规划分数不足目标会停止并保存棋盘。

离线搜索不需要打开游戏，也不控制鼠标：

```bash
mkdir -p runs
./GameAssistant solve --board-file fixtures/board-a.txt --target 160 \
  --best-effort --search-seconds 32 --strategy portfolio8 --seed 7 --out runs/plan.json
```

先创建输出目录，例如 `mkdir -p runs`。棋盘文件首行为行列数，后续为按行排列的数字，0代表空格。多策略对照：

```bash
GAME_BENCH_SECONDS=32 GAME_BENCH_STRATEGIES=portfolio8,perfect8 \
  ruby scripts/benchmark.rb runs/comparison fixtures/board-a.txt fixtures/board-b.txt
ruby scripts/benchmark_report.rb runs/comparison portfolio8 perfect8
```

若仍是同一局、窗口图像尺寸一致，可以恢复检查点：

```bash
./GameAssistant play --resume runs/my-round/checkpoint.json --output runs/my-round
```

动作在发送前写入检查点，确认生效后再提交；恢复时区分已生效和未生效的动作。棋盘无法匹配时停止。连续控制器恢复示例及坐标校准见 [运行说明](docs/usage.md)。

## 已有结果

| 会话 | 时间 | 记录棋盘数 | 完整验证局数 | 最高实测 |
| --- | --- | ---: | ---: | ---: |
| [七小时挑战](results/session-20261110-005453/SUMMARY.md) | 7小时零40秒 | 183 | 179 | **159** |
| [后续满分尝试](results/session-20261110-130618/SUMMARY.md) | 屏幕切换后重新计时40分02秒 | 79 | 6 | **155** |

七小时挑战中，149局超过123分，22局至少150分；另有4局失败并保留记录。后续79张棋盘中，71张因必要条件失败重开，1张预算内未搜到满分后重开，1局在切换窗口后保护性停止。完整执行、主动重开和失败不会混为一种成绩。所有数字均来自实际记录；合成测试中的160分不算游戏实测满分。

详见 [结果索引](docs/results.md)、[策略与实验](docs/strategies.md) 和各会话的 `report.json` / `artifact-audit.json`。

## 目录

```text
src/        当前 Swift 自动化与 C++ 搜索器源码
scripts/    构建、自测、启动、对照、统计和核查脚本
configs/    普通得分与满分冲击配置
fixtures/   可脱离原工作目录运行的回归样本
tests/      满分必要条件与束搜索检查
docs/       运行细节、策略、结果说明
results/    两轮历史逐局记录、截图、算法对照和历史源码快照
runs/       新运行输出（Git忽略）
```

当前默认策略为 `portfolio8`。实验策略 `perfect8` 包含满分约束随机搜索与束搜索，尚未显示优于默认组合的证据。主程序支持的是数字消除后留空、其余数字不移动的16×10棋盘；不支持下落、补充数字或不同规则。小程序分享口令自动解析启动尚未实现。
