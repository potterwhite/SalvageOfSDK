# sdk-reclaim

**把一个被厂家剥掉元数据的 SDK 压缩包，变回可以 `repo` 管理的多仓库工程。**

面对的场景：厂家（二层开发板商）给你一个 10GB 的 `tar.xz`，里面 55 个 `.git` 全是断链符号链接，`.repo/` 已被删除，git 历史归零。你要把它变成团队能 `repo init && repo sync` 拉下来、能编译、能跑的工程。

---

## 一、为什么需要一个工具，而不是一个脚本

朴素做法是写一个循环：遍历每个项目 → `git init` → `git add .` → `commit` → `push`。这个做法**会成功运行，并且悄悄丢文件**。

在真实的 rk3576 SDK 上，它会丢掉：

- `docs/` 下 **322 个 Rockchip PDF 文档**（不可再生）
- `external/mpp/build/` 下 **27 个交叉编译脚本**（丢了 mpp 编不出来）
- `kernel-6.1` 的 **Mali GPU 固件** `mali_csffw.bin`（丢了 GPU 跑不起来）
- `debian/` + `ubuntu/` 共 **2.3GB**（厂家板级定制的主体，零 `.git`）

而且**不会报任何错**。你几个月后要查一份数据手册时才会发现。

根因有两个：

1. **`.gitignore` 是给上游开发流程写的，不是给你的快照写的。** 上游可以 `git add -f` 强加文件，历史里有记录就永久跟踪；**你没有历史，所以每一个这样的决定都必须重做一次**。
2. **`find -name ".git"` 会骗你。** 它把断链符号链接和真实仓库报告成一样。55 个"仓库"实际是 55 个断链——如果不先分类就动手，你会以为有 55 份历史可救，实际是 0。

所以工具的价值不在"自动化推送"，而在**把所有隐性损失变成一份显式的、人可审查的清单**。

---

## 二、四阶段架构：核心是那条线

```
┌──────────────────────────────────────────────────────────────┐
│                      SDK 目录（10GB）                         │
│         55 个断链 .git  +  未知的孤儿  +  未知的 ignore 损失   │
└────────────────────────────┬─────────────────────────────────┘
                             │
              ┌──────────────▼──────────────┐
              │   ① extract.py  【只读】     │
              │   诊断损坏类型               │
              │   提取项目清单（从符号链接）  │
              │   找孤儿 / 大文件 / ignore   │
              └──────────────┬──────────────┘
                             │
                   ┌─────────▼─────────┐
                   │  inventory.json   │  ← ★ 稳定契约 ★
                   │  人可读 / 可 diff  │     纯文本，可进版本控制
                   └─────────┬─────────┘
                             │
         ╔═══════════════════▼═══════════════════╗
         ║        ★ 人工审查闸门 ★               ║   ← 唯一需要
         ║  给每条 ignore 损失标 keep / drop     ║      工程判断的地方
         ║  每个 drop 都要写理由                 ║
         ╚═══════════════════╤═══════════════════╝
                             │
              ┌──────────────▼──────────────┐
              │   ② verify.py   【只读】     │
              │   6 项断言，有问题 exit 1    │
              │   ★ 未分类项 = 硬失败 ★      │
              └──────────────┬──────────────┘
                             │  只有全部通过才能往下
              ┌──────────────▼──────────────┐
              │   ③ execute.py  【幂等】     │
              │   只读 inventory，不再判断   │
              │   state.json 支持 --resume   │
              │   对 keep 项用 git add -f    │
              └──────────────┬──────────────┘
                             │
              ┌──────────────▼──────────────┐
              │   ④ manifest.py + 验证       │
              │   生成 default.xml           │
              │   repo sync → diff -r 原树   │
              │   → ./build.sh 出 update.img │
              └──────────────────────────────┘
```

### 那条线是什么

**在「提取事实」和「执行变更」之间，横着一条不可逾越的线。** 上面只读，下面才写。

原来的一体式脚本把两者混在一个循环里，产生三个结构性缺陷：

| 缺陷 | 表现 |
|---|---|
| **破坏性** | `rm -rf .git` 之后 push 失败 → 原状态不可恢复 |
| **不可重放** | 重跑时走到 `.git not found` → **静默 `continue` 跳过**，你以为成功了 |
| **不可审查** | 决策发生在运行时，人看不到，无法在执行前 review |

拆开之后，失败永远发生在只读阶段，代价是零。

### 为什么这叫"降熵"

高熵来自**未知的未知**。`inventory.json` 的作用是把所有未知**物化成一份文本**。

一旦落到文本，它就能被 `diff`、被 code review、被提交进 git、在换下一个 SDK 时**对比差异**。

**换 SDK 时只有 `extract.py` 需要适配，后三段的契约不变。** 这是这套方法能复用的根本原因——SDK 特定的脏活被隔离在一个地方。

---

## 三、模块如何协作

```
                          cli.py
                    （argparse 分发，四个子命令）
                             │
        ┌────────────┬───────┴───────┬──────────────┐
        ▼            ▼               ▼              ▼
   extract.py    verify.py      execute.py     manifest.py
    【只读】      【只读】        【未实现】      【只读】
        │            │               │              │
        │ 写         │ 读            │ 读           │ 读
        ▼            ▼               ▼              ▼
   ┌─────────────────────────────────────────────────────┐
   │              inventory.json                          │
   │   模块间【唯一】的通信媒介。没有共享内存状态，        │
   │   没有隐式耦合。每个模块可独立测试和替换。            │
   └─────────────────────────────────────────────────────┘
```

**关键设计：模块之间不互相 import**（除了 `cli.py` 按需延迟导入）。它们只通过 `inventory.json` 通信。所以你可以用任何语言重写任何一个阶段，只要遵守 JSON 契约。

### 各模块职责

| 模块 | 输入 | 输出 | 副作用 |
|---|---|---|---|
| `extract.py` | SDK 目录 | `inventory.json` | **无**（对 SDK 全程只读） |
| `verify.py` | `inventory.json` | 报告 + exit code | **无** |
| `execute.py` | `inventory.json` | GitLab 项目 + `state.json` | 写 GitLab、写 `.git` |
| `manifest.py` | `inventory.json` | `default.xml` | 无 |

---

## 四、extract.py 里最重要的三个函数

### `classify_git_entry()` — 为什么 `find` 会骗你

```python
if p.is_symlink():
    target = os.readlink(p)
    return ("real-dir" if p.exists() else "broken-symlink"), target
```

`p.exists()` 会跟随符号链接，所以返回 `False` 就意味着**断链**。

顺序很重要：`is_symlink()` 必须在 `is_dir()` 之前判断。否则一个恰好能解析的符号链接会被误报成 `real-dir`，而**丢掉 target 路径——那是我们唯一的化石证据**。

### `diagnose()` — 三种损坏类型，做法完全不同

| 诊断 | 含义 | 正确做法 |
|---|---|---|
| `healthy` | `.repo` 在，真实仓库在 | 正常解析清单，**别用这个工具** |
| `repo-meta-deleted` | `.repo` 没了但对象库还在 | **历史可抢救！先救再重建** |
| `metadata-stripped` | 只剩断链符号链接 | 历史不存在，只能快照重建 |

**判错 `repo-meta-deleted` 是代价最大的错误**——你会毫无必要地摧毁可恢复的历史。所以工具第一件事就是报诊断，让你在动手前看到。

### `audit_ignored()` — 全工具最重要的函数

```python
# 裸仓库建在 /tmp，--work-tree 指向 SDK
# → git 能回答 ignore 问题，但绝不在 SDK 里创建 .git
gd = os.path.join(probe, p.replace("/", "_") + ".git")
_run(["git", "init", "-q", "--bare", gd])
_run(["git", f"--git-dir={gd}", f"--work-tree={wt}",
      "ls-files", "-o", "-i", "--exclude-standard"])
```

`-o` 列出未跟踪文件，`-i` 限定到其中被忽略的。新仓库里什么都没跟踪，所以结果恰好是 **`git add .` 会跳过的集合**。

**为什么必须问 git，不能自己解析 `.gitignore`：**

`external/mpp` 是决定性证据：

```
external/mpp/.gitignore:87:      /build          ← 根规则排除整个 build/
external/mpp/build/.gitignore:   !*.bash         ← 嵌套规则想救回脚本
```

```bash
$ git check-ignore -v build/linux/aarch64/make-Makefiles.bash
.gitignore:87:/build   build/linux/aarch64/make-Makefiles.bash
     ↑ 根规则获胜
```

**根规则排除了整个目录，git 就不再下降进入其中，所以嵌套的 `!*.bash` 永远不可达。** 上游必然是靠 `git add -f` 强加的。

⇒ **任何"读 `.gitignore` 文本来推断"的实现都是错的。** git 的目录剪枝语义让人的直觉失效。

---

## 五、怎么用

```bash
cd /development/src/sdk/linux/sdk-reclaim

# ① 只读扫描（不写 SDK、不碰网络）。55 个项目各跑一次 ls-files，需要几分钟
python3 -m sdk_reclaim extract /home/developer/sdk/linux/rk3576-linux-6.1 \
        -o inventory.json

# ② 第一次【必然失败】—— 这是设计意图，不是 bug
python3 -m sdk_reclaim verify inventory.json
#   → "610 ignored file(s) have no keep/drop rule. Refusing to guess"
```

### 人工审查（唯一需要工程判断的一步）

在 `inventory.json` 的 `ignored_adjudication` 数组里填规则。**顺序敏感，先匹配的先赢**，所以特例写在前面：

```jsonc
"ignored_adjudication": [
  { "pattern": "docs/cn/**/*.pdf", "action": "keep",
    "reason": "Rockchip 开发文档，不可再生（322 个）" },
  { "pattern": "external/mpp/build/**", "action": "keep",
    "reason": "交叉编译脚本，被根规则 /build 误伤；上游靠 add -f" },
  { "pattern": "**/mali_csffw.bin", "action": "keep",
    "reason": "Mali GPU 固件，运行必需" },
  { "pattern": "buildroot/dl/**", "action": "drop",
    "reason": "上游下载缓存 2.5GB，可重新下载" },
  { "pattern": "external/rkwifibt/**/*.cmd", "action": "drop",
    "reason": "内核编译残留（厂家脏树）" }
]
```

**每个 `drop` 都必须有证据，不能靠猜。**

范例——`device/rockchip/.gitignore` 内容是 `.*` + `/*`（极激进），会丢掉 `.chip` 符号链接。判定它安全的依据不是"看起来像临时文件"，而是找到了：

```
device/rockchip/common/scripts/mk-config.sh:19:  rm -rf "$RK_CHIP_DIR"
device/rockchip/common/scripts/mk-config.sh:20:  ln -rsf "$(dirname "$DEFCONFIG")" "$RK_CHIP_DIR"
```

构建期会重建 → 可以安全丢弃。**这才是一条合格的 drop 理由。**

```bash
# ③ 直到 unclassified 归零
python3 -m sdk_reclaim verify inventory.json && echo "READY"

# ④ 生成清单
python3 -m sdk_reclaim manifest inventory.json \
        --host 192.168.3.67 --group team_rk3576 --protocol ssh \
        -o default.xml
```

---

## 六、verify.py 的 6 项断言

每一项都对应一次真实的踩坑。写成断言，就不会再犯第二次。

| # | 断言 | 不做会怎样 |
|---|---|---|
| 1 | 扁平化后无命名冲突 | `/`→`-` 后两个路径撞名，第二次 push **强制覆盖第一个**，仓库内容错了但无任何报错 |
| 2 | 父仓库排除嵌套子仓库 | `docs/` → `docs/cn/` → `docs/cn/RK3576/` 三层。父提交吞掉子文件，`repo sync` 时冲突 |
| 3 | **每个 ignore 文件已分类** | **静默丢 322 个 PDF / 27 个编译脚本** |
| 4 | 超限文件已配 LFS | push 到第 40 个项目才失败，GitLab 组已半迁移 |
| 5 | 无 `.` 开头的 path | repo 报 `bad component`，且残缺的 `.repo` 无法修复，只能删目录重来 |
| 6 | 孤儿有归属 | **debian/ + ubuntu/ 共 2.3GB 直接消失** |

---

## 七、execute.py 为什么故意没实现

它是唯一会写 GitLab、写磁盘的阶段。**在你审过 `inventory.json` 之前就把它写出来，等于鼓励跳过审查闸门**——而那个闸门是唯一能防住静默丢数据的东西。

现在跑它会打印契约然后 `exit 2`：

```
- 只读 inventory.json，运行时不再做任何判断
- 幂等创建 GitLab 项目（GET 探测 → POST，容忍 400 already taken）
- 每项目：git init -b main → 写 .gitattributes(LFS) → git add
          → 对每条 keep 规则 git add -f → commit → push
- 状态落盘 state.json 支持 --resume
- 绝不 rm -rf SDK 内任何东西
- token 从 $GITLAB_TOKEN 读，完成后清理 .git/config 里的凭证
```

最后一条很重要：`auth_url` 方案会把 PAT 明文写进 55 个 `.git/config`。收尾要清理：

```bash
find . -name config -path "*/.git/*" -exec \
  sed -i 's|://[^:]*:[^@]*@|://|' {} \;
```

---

## 八、为什么选 Python

不是偏好，是三条具体理由：

1. **`repo` 本身就是 Python**（本机 launcher 2.17 / Python 3.10）。用户环境里必然有。
2. **核心工作是调 `git` + 处理 XML/JSON**，无计算瓶颈。Rust 的性能优势在这里用不上——瓶颈是 `git` 子进程和磁盘 IO。
3. **读者是嵌入式工程师。** 这个工具的价值在于被人读懂、被人改。Python 门槛最低。

**选它是因为要被人读和改，不是因为要快。**

---

## 九、验收标准

不是"脚本跑完没报错"，而是：

```bash
# 干净目录重新拉取
mkdir /tmp/verify && cd /tmp/verify
repo init -u git@192.168.3.67:team_rk3576/rk3576-manifests.git \
     -b main --no-clone-bundle
repo sync -j8
git lfs pull                    # ★ LFS 必须这步

# 与原树逐字节比对
diff -r --no-dereference --brief \
     /home/developer/sdk/linux/rk3576-linux-6.1 /tmp/verify \
     | grep -v -f known-drops.txt      # 必须为空

# 终极验收：能编译出可运行的固件
./build.sh lunch      # 选 topeet_rk3576_defconfig
./build.sh            # → output/firmware/update.img
```

**"没报错"不等于"成功"。** 原脚本失败后重跑会静默跳过。终态验证不可省略。

---

## 十、可复用的经验（不限于 SDK）

1. **`find -name ".git"` 会骗你。** 先用 `-xtype l` / `-type d` 分类，再行动。
2. **区分"本地损坏"和"上游剥离"。** 扫原始压缩包即可判定，省下大量徒劳。
3. **断链的符号链接是化石。** 它的 target 保存了原始结构。损坏的元数据往往仍携带可提取信息，别急着删。
4. **`.gitignore` 是给上游写的，不是给你的快照写的。** 用 `git check-ignore -v` 逐文件裁决，每个 drop 都要有证据。
5. **只读取证工具绝不能污染现场。** `git init --bare` 到临时目录 + `--work-tree`。
6. **在"提取事实"和"执行变更"之间划线。** 中间产物必须是人可读、可 diff 的文本。
7. **拒绝猜测胜过静默默认。** 不知道就硬失败。静默的不完整比响亮的失败危险得多。
8. **诚实记录损失。** 历史确实丢了、某些文件确实没进 git——写进文档，而不是假装完整。

---

## 附：当前状态

| 阶段 | 状态 |
|---|---|
| `extract.py` | 逻辑完整，**未在真实 SDK 上跑过** |
| `verify.py` | 逻辑完整，未跑过 |
| `manifest.py` | 逻辑完整，未跑过 |
| `execute.py` | **故意未实现**（见第七节） |

侦察阶段的**事实**（55 个断链、610 条 ignore 损失、70 个孤儿、9 个大文件、`mpp` 的不可达规则）全部是本机实测验证过的。**这些代码是把那些手工命令固化下来的产物，本身尚未端到端跑通。**
