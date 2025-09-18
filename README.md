# TuShare Token 验证脚本

这个小工具用于通过 TuShare 的用户配额接口验证本地环境中的 Token 是否有效，并打印即将到期的积分（如有）。

> 脚本文件名在文档中以 `project_tools/script.py` 占位，请替换成你的真实文件名。

## 功能概览

* 从环境变量中读取多个 TuShare Token（默认键：`TUSHARE_TOKEN`、`TUSHARE_TOKEN_2`）。
* 自动寻找并加载最近的 `.env` 文件填充环境变量。
* 调用 `pro.user` 检查 Token 有效性并获取配额信息。
* 以人类可读的形式打印结果；当无任何有效 Token 时以非零状态退出。

## 运行环境

* Python ≥ 3.10（使用了 `typing` 的联合类型 `|` 语法）
* 依赖库：

  * [`tushare`](https://pypi.org/project/tushare/)

## 安装

```bash
# 建议使用虚拟环境
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate

pip install --upgrade pip
pip install tushare
```

## 配置

### 环境变量键

脚本默认检查以下两个环境变量，可自行在源码中扩展或修改：

* `TUSHARE_TOKEN`
* `TUSHARE_TOKEN_2`

### `.env` 自动加载

运行时会在以下路径顺序中寻找第一个存在的 `.env` 并加载（后续路径不再处理）：

1. 当前工作目录下的 `.env`
2. 脚本所在目录及其逐级父目录下的 `.env`

`.env` 文件格式示例：

```dotenv
# 以实际 Token 替换下面的占位
TUSHARE_TOKEN=your_primary_token_here
TUSHARE_TOKEN_2=your_backup_token_here
```

> `.env` 中的值支持用引号包裹；以 `#` 开头的行为注释；空行会被忽略。

## 使用方法

```bash
python script.py
# 或使用绝对/相对路径：python path/to/script.py
```

### 退出码

* 成功：如果至少有一个 Token 验证通过，进程以 `0` 退出。
* 失败：若所有 Token 均无效，进程以非零状态退出，并输出

  ```
  未检测到有效的 TuShare Token。
  ```

### 输出示例

成功（其中一个 Token 有效，且返回了积分到期明细）：

```
----------------------------------------
环境变量: TUSHARE_TOKEN
用户 ID: 123456
积分明细: [{"user_id":"123456","...": "..."}]
----------------------------------------
环境变量: TUSHARE_TOKEN_2
检测失败: 环境变量 TUSHARE_TOKEN_2 未设置。
```

成功（有效但无到期记录）：

```
----------------------------------------
环境变量: TUSHARE_TOKEN
用户 ID: 123456
积分明细: [] (未返回即将到期的积分记录)
```

失败（全部无效或调用失败）：

```
----------------------------------------
环境变量: TUSHARE_TOKEN
检测失败: 调用 TuShare 接口失败: Invalid token
----------------------------------------
环境变量: TUSHARE_TOKEN_2
检测失败: 环境变量 TUSHARE_TOKEN_2 未设置。
未检测到有效的 TuShare Token。
```

## 工作原理

1. 加载 `.env`（若存在）到进程环境。
2. 按 `ENV_KEYS` 中定义的键依次读取 Token。
3. 对每个 Token 调用 `ts.pro_api(token=...)` 和 `pro.user(token=...)`：

   * 若抛异常或返回空对象，视为失败并记录原因。
   * 若返回 DataFrame，则：

     * 读取首行的 `user_id`
     * 用 `df.to_json(orient="records", force_ascii=False)` 序列化所有行，打印为“积分明细”
     * 标记该 Token 检查成功
4. 若所有 Token 均失败，抛出 `SystemExit` 并以非零状态结束。

## 常见问题

**Q: 只有一个 Token 怎么办？**
A: 只设置 `TUSHARE_TOKEN` 即可。未设置的键会被报告为“未设置”，不影响另一个的验证。

**Q: 想检查更多 Token？**
A: 在源码顶部的 `ENV_KEYS` 中追加你的环境变量名即可，例如：

```python
ENV_KEYS = ("TUSHARE_TOKEN", "TUSHARE_TOKEN_2", "TUSHARE_TOKEN_ALT")
```

**Q: 可以只打印通过的 Token 吗？**
A: 当前脚本会逐一打印全部检查结果，便于排查。可自行按需改造输出逻辑。

**Q: DataFrame 为什么可能有多行？**
A: `pro.user` 在有多条即将到期配额时会返回多行，脚本会把所有行序列化为 JSON 串统一打印。

## 故障排除

* `环境变量 XXX 未设置。`
  确认在 shell 中已导出，或 `.env` 放在上述搜索路径之一。
* `调用 TuShare 接口失败: ...`

  * Token 不正确或过期
  * 网络问题或被限流
  * TuShare 服务端异常
* `TuShare 返回空对象`
  通常是服务端返回异常结构或网络中断，重试或更换网络环境。

## 安全提示

* 输出中可能包含账户相关信息与配额细节，避免将完整日志公开粘贴到外部平台。
* `.env` 文件不要提交到版本控制；建议将其加入 `.gitignore`。

## 在 CI 中使用

可以在流水线里快速验证凭据是否可用：

```yaml
# 以 GitHub Actions 为例
- name: Verify TuShare tokens
  run: |
    pip install tushare
    python script.py
```

利用非零退出码自动阻断后续步骤，防止凭据失效后仍继续部署或任务执行。

## 许可证

根据你的项目选择合适的开源许可证（MIT、Apache-2.0 等）。若未指定，则默认保留所有权利。

---

需要我顺手把脚本参数化、加上 `--json` 或 `--quiet` 之类的开关，也能一把梭。
