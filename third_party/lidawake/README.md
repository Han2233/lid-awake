# lidawake（内置）

- 上游：https://github.com/richardlinq/lidawake
- 版本：v0.2.0（9ba9476）
- 许可：Apache-2.0，完整文本见 [LICENSE](LICENSE)

## 内置的文件

| 文件 | 说明 |
|---|---|
| `bin/lidawake` | 模式、电量阈值、合盖锁屏/关背光、守护进程 |
| `bin/lidtest` | 上游的合盖验证工具 |
| `src/dispbright.c` | 40 行 C，通过 DisplayServices 控制背光；安装时用 clang 编译 |
| `share/sudoers.in` | 上游的 sudoers 模板（本项目的 App 会自己生成等价规则） |

## 修改

未修改上游代码。`scripts/install.sh` 只做两件事：复制到
`~/Library/Application Support/lidawake/`，以及编译 `dispbright`。

上游 README 与更新记录请见 https://github.com/richardlinq/lidawake 。
