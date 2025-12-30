# pack_fpga_repro.sh

在 FPGA 工程目录执行 `tools/pack_fpga_repro.sh`，用于在 `make all` 生成 bitfile 后，将复现所需文件打成一个 `tar.gz`，供软件/验证同事交付使用。

## 用法

```bash
tools/pack_fpga_repro.sh --dest <destination_dir> [--dest2 <path>] [--buildid <id>] [--dry-run]
```

### 参数

- `--dest <destination_dir>`（必填）：输出 `tar.gz` 放置目录（等价于 `--dest1`）。
- `--dest1 <path>`（可选）：归档目录（优先于 `--dest`）。
- `--dest2 <path>`（可选）：投递目录（用于投递 redcomp tarball 并解压）。
- `--no-dest2`（可选）：显式关闭 dest2 投递行为。
- `--buildid <id>`（可选）：自定义构建 ID。
  - 默认值：`YYYYMMDD_HHMMSS_<host>_<user>`
- `--dry-run`（可选）：只打印将要收集的文件，不真正打包。

## 收集内容

1. **FPGA 工程根目录输入类文件（仅当前目录，不递归）**
   - 后缀：`*.xdc *.tcl *.phd *.rdc *.cfg *.v *.f`
   - 统一放入 `repro_<buildid>/fpga_root_inputs/` 下（保留相对路径层级）

2. **redcomp.out/rtlc/_red_veloce.log**
   - 只打包该目录及其内容

3. **redcomp.out/spnr/MB*_* 下 tag_redfpga_* 目录的关键产物**
   - `vivado.log`
   - `vivado.jou`
   - `post-route_reports/` 目录
   - 会对 symlink 执行 dereference/copy-links，确保 staging 中为真实文件/目录内容
   - 若缺失会记录到 `meta/missing_files.txt`，但脚本继续执行

4. **环境变量与 design 目录快照**
   - `meta/env.txt`：`env | sort` 结果（敏感字段脱敏）
   - design 目录：
     - 优先使用环境变量 `DESIGN_HOME`
     - 未找到时从环境变量中检索包含 `/design` 或 `design_` 的路径
   - `meta/design_git_head.txt` / `meta/design_commit_id.txt`
   - `design_snapshot/`：design 目录完整拷贝

## 产物结构示例

```
repro_<buildid>/
  meta/
    manifest.txt
    env.txt
    design_git_head.txt
    design_commit_id.txt
    missing_files.txt
  fpga_root_inputs/
  redcomp.out/rtlc/_red_veloce.log/...
  redcomp.out/spnr/MB*/tag_redfpga_*/(vivado.log|vivado.jou|post-route_reports/...)
  design_snapshot/
```

## 输出

- `fpga_repro_<buildid>.tar.gz` 将输出到 `--dest1/--dest` 指定目录。
- 完成后会打印 tar.gz 文件名（不显示 DEST1 真实路径）。

### DEST1/DEST2 双向关联文件

当同时提供 `--dest1/--dest` 与 `--dest2` 时，会在两端生成互指针文件，记录双方真实绝对路径：

- `DEST1/LINK_DEST2.txt`
- `DEST2/LINK_DEST1.txt`
- `DEST1/README_DEST1_LINK.txt`（包含 DEST1/DEST2 绝对路径）

这两个文件包含 BUILDID、时间、用户、`DEST1_ABS_PATH`、`DEST2_ABS_PATH`、归档包名称及 SHA256，
便于软件侧与归档侧互相定位。

### DEST2 投递说明

当提供 `--dest2` 时，脚本会从 `redcomp.out/` 目录下收集 `*.tar.gz`（仅这一层），并执行：

1. 复制到 `dest2` 目录
2. 解压到 `dest2` 根目录
3. 删除 `dest2` 下的 `*.tar.gz`
4. 对 `dest2` 目录执行 `chmod -R 777`

脚本会在 dest2 根目录生成 `README_DEST2_LINK.txt`，内容示例：

```
该目录为 FPGA server 投递区，与 DEST1 归档区对应。
BUILDID: 20240819_120000_host_user
TIME: 20240819_120000
HOST: host
USER: user
DEST1_ABS_PATH=/path/to/dest1
DEST2_ABS_PATH=/path/to/dest2
Delivered tarballs:
- redcomp.outputs.20251225_182500.tar.gz
Extracted: extracted into DEST2 root (chmod 777)
Full repro package: fpga_repro_20240819_120000_host_user.tar.gz (stored in DEST1)
```

## 依赖

脚本会检查以下依赖：

- `tar`
- `gzip`
- `rsync`（若不存在则使用 `cp --parents`）
- `git`（可选，缺失时仅跳过 git 信息采集）

## 示例

```bash
# 正常打包
tools/pack_fpga_repro.sh --dest /tmp

# 自定义 build id
tools/pack_fpga_repro.sh --dest /tmp --buildid 20240819_demo

# dry-run 仅查看将收集的文件
tools/pack_fpga_repro.sh --dest /tmp --dry-run
```
