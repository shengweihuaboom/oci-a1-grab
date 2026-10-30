# oci-a1-grab

定时尝试在 Oracle Cloud（大阪）创建一台 Always Free 的 Arm 服务器（2 OCPU / 12 GB）。

- 接力运行：每次尝试结束约 4 分钟后，自动触发下一次（约 5 分钟一次）。另有每小时一次的定时检查，接力断了会自动接上。也可以在 Actions 页面手动点 Run workflow。
- 想全部停下：在 Actions 页面把这个 workflow 停用（Disable workflow）。
- 没空位或被限流：本次算成功（绿色），等下次再试。
- 建成功：自动停用定时任务，并新建一个 issue 通知。
- 其他错误：本次失败（红色），GitHub 会发邮件。

需要的 Secrets：`OCI_CONFIG`（Oracle 生成 API 密钥后给的配置文件预览，原样粘贴）和 `OCI_PRIVATE_KEY`（下载的私钥文件内容）。
