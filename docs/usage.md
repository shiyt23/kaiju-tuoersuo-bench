# 运行细节

所有命令从仓库根目录执行。首次使用先运行 `./scripts/build.sh` 和 `./GameAssistant status`。权限应授予实际承载命令的终端或宿主应用；授予权限后可能需要重启该应用。

## 窗口和布局

程序按标题“开局托儿所”定位游戏窗口。同名窗口不止一个时，用 `status` 输出中的窗口ID指定：

```bash
mkdir -p runs
./GameAssistant capture --window 你的窗口ID --out runs/game.png
./GameAssistant play --window 你的窗口ID --target 150 --best-effort --output runs/one
```

`capture`、`solve --out` 的父目录需提前创建。截图默认按已验证的704×1338布局比例缩放，棋盘16行10列、参考区域为 `(24,226,656,1050)`。需要校准时：

```bash
mkdir -p runs
./GameAssistant capture --out runs/game.png
./GameAssistant analyze --image runs/game.png --board 24,226,656,1050 --rows 16 --cols 10
```

`--board` 是截图像素中的 `x,y,width,height`，需根据实际截图填写；`click --at X,Y` 使用窗口内逻辑坐标，单位不同。切换显示器、移动或缩放窗口会触发保护。新的连续会话应重新定位窗口，不要对变化后的画面继续沿用旧控制器。

## 连续控制器与配置

`scripts/run-session.sh` 负责创建空目录、复制模式配置、写会话元信息并保持系统唤醒。底层命令为：

```bash
./GameAssistant session --until UNIX截止时间 --output runs/会话目录
```

配置项如下：

| 字段 | 用途 |
| --- | --- |
| `strategy` | `portfolio8`为默认；其他策略见策略文档 |
| `target` | 规划目标，连续模式最多160 |
| `search_seconds` | 搜索预算，最多60秒 |
| `full_clear_focus` | 不满足基础满分条件时，将长预算降到最多32秒 |
| `skip_impossible_full_clear` | 先检查必要条件，失败则保存证据并在界面确认放弃 |
| `full_clear_only` | 只执行完整清空路径，其余保存计划并重开 |

连续模式始终保存最佳搜索结果。快速重开功能需要控制器配合，建议通过配置使用，不要单独给 `play` 加相关内部选项后期待它自动操作结算或设置界面。

## 中断与恢复

同一局恢复用 `play --resume`，恢复前先确认棋盘、尺寸与检查点一致。控制器在结算或主界面恢复时，需要指定最后一局和下一空编号，避免覆盖数据：

```bash
./GameAssistant session --until UNIX截止时间 --output runs/会话目录 \
  --adopt-run runs/会话目录/round-012 --start-index 13
```

`--start-index` 必须指向未使用编号。此前创建的 `STOP`、`DRAIN` 或 `HOLD` 文件需按需要移除。原会话的 `session.json` 和新的截止时间应保持一致，以便统计真实运行时间。

## 留痕与核查

| 文件 | 内容 |
| --- | --- |
| `initial.png` / `initial-board.txt` | 初始截图与160格识别结果 |
| `plan.json` | 已独立回放验证的路径、得分、种子、各线程得分与搜索耗时 |
| `planning-budget.json` | 本局实际选择的搜索预算 |
| `checkpoint.json` / `actions.jsonl` | 待确认动作、已验证棋盘和逐步操作记录 |
| `settlement.png` / `result.json` | 实际结算截图和最终成绩 |
| `eligibility.json` / `skip-request.json` | 满分筛选结果、重开原因或未执行的最佳计划 |
| `abandon-confirm.png` / `abandoned.png` | 主动重开的确认与返回主界面证据 |
| `provenance.json` | 源码和程序哈希、种子、策略和配置 |

会话级 `events.jsonl`、`state.json`、`ads/` 记录控制流程、广告奖励与续期。未知画面、前台变化或识别失败会保留错误日志；不要把失败局或未执行的计划计为完整实测成绩。

```bash
ruby scripts/report.rb runs/会话目录
ruby scripts/audit.rb runs/会话目录
```

对仓库历史资料使用 `audit.rb 会话目录 --check` 做只读核查，避免重写已经归档的报告。历史源文件哈希对应当时版本，不对应当前整理后的目录结构。
