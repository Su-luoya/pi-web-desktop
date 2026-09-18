## 变更说明

<!-- 说明用户问题、实现范围和不包含的内容，并关联对应 Issue。 -->

Closes #

## 类型与标签

<!-- 与仓库标签体系保持一致；维护者会按实际影响调整。 -->

- type: <!-- bug / feature / maintenance / documentation / security -->
- area: <!-- app / service / diagnostics / security / updates / build-release / documentation -->
- priority: <!-- P0 / P1 / P2 / P3，由维护者在分诊时确认 -->

## 验收证据

<!-- 列出实际执行的命令与结果。不要复述文档或凭记忆填写版本号与路径。 -->

- [ ] `sh -n Scripts/*.sh`
- [ ] `git diff --check`
- [ ] `./Scripts/build.sh`
- [ ] `./Scripts/check-identity.sh` 退出 0
- [ ] `./Scripts/smoke.sh`（不适用时说明原因）
- [ ] `codesign --verify --deep --strict build/Pi-Web-Desktop.app`
- [ ] personal-data 扫描通过（`Scripts/check-identity.sh` 或工作流里的 `git grep`）
- [ ] Swift 代码变更已跑 `xcodebuild build` / `xcodebuild test`；无法执行时说明由哪一步 CI 覆盖
- [ ] 已检查 diff，没有凭据、私人路径、主机名、代理信息或 token
- [ ] 已同步更新用户可见文档

命令输出摘要：

```text

```

## 文档与命令核对

- [ ] 文档新增或修改的每条命令都已实际执行，结果写在上面的证据里
- [ ] 无法在当前环境执行的命令已显式标注为未执行，并说明覆盖方式
- [ ] 文档没有“稳定版”“已签名”“已公证”“保证兼容”“支持 Intel”“自动更新已就绪”等未兑现表述（本行只作为禁止清单，不作为现状描述）

## 安全与兼容性

<!-- 说明进程、网络、Keychain、更新、日志和支持矩阵影响。远程访问相关改动必须说明“密码认证 ≠ 传输加密”。 -->

## 人工验证

<!-- 无法自动测试的 UI、Keychain、WebKit、Gatekeeper 行为：写清操作步骤与观察到的结果。 -->

## 遗留与不确定项

<!-- 未完成、未验证或需要后续跟进的事项；没有请写“无”。 -->
