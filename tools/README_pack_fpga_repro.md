# pack_fpga_repro.sh

在 FPGA 工程目录执行 `tools/pack_fpga_repro.sh`，用于在 `make all` 生成 bitfile 后，将复现所需文件打成一个 `tar.gz`，供软件/验证同事交付使用。

## 用法

```bash
tools/pack_fpga_repro.sh --dest <destination_dir> [--buildid <id>] [--dry-run]
```

### 参数

- `--dest <destination_dir>`（必填）：输出 `tar.gz` 放置目录。
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

- `fpga_repro_<buildid>.tar.gz` 将输出到 `--dest` 指定目录。
- 完成后会打印最终 tar.gz 路径。

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
