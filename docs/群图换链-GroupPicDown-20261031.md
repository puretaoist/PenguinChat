# 群图直链过期 → 凭 fileid 换链（GroupPicDown）

日期：2026-10-31　范围：`lib/kernel/wlogin8/qq8_image.dart`、`lib/kernel/wlogin8/qq8_elem.dart`、`lib/client_api/segment.dart`、`lib/client_api/qq8_session_adapter.dart`、`lib/infra/storage/media_cache.dart`、`lib/client_api/chat_store.dart`、`lib/client_api/qq8_login_service.dart`、`lib/client_api/qq8_providers.dart`

## 1. 问题

腾讯的图片直链里带 `rkey`，几小时后必然失效：实测 `HTTP 400` + `{"retcode":-5503007,"retmsg":"download url has expired"}`。
P2 已证明**重拉历史拿不到新 rkey**（服务端不重签，甚至会把签名直链降级成 `gchatpic_new/0/0-0-<MD5>/0` 的死链，见 `docs/图片直链刷新实验-P2结论-20261031.md`）。
结果是：群聊里三天前的图，本地没缓存过就永远打不开。

## 2. 结论：官方 `ImgStore.GroupPicDown` 能给新链

反编译 QQ 8.2.11 的 `Layux;`（`ImgStore.GroupPicDown` 的组包类）得到结构：它**不是高优通道下载，而是一个 WUP 请求换 URL**。

- 请求体 `tencent.im.cs.cmd0x388.ReqBody`：`uint32_subcmd=2`、`uint32_net_type`、`rpt_msg_getimg_url_req`（`GetImgUrlReq`）。
- 回执里 `GetImgUrlRsp` 的 `bytes_original_down_para` / `bytes_big_down_para` / `bytes_thumb_down_para` 就是**下载参数的路径**，配上 `bytes_down_domain` 即可下载。

真机实测（群 486045673，seq 59162，md5 `03a32b46…`，fileid `343328515`）：

| 参数组合 | 结果 |
| --- | --- |
| `dst=self`，不给 fileid | `result=206 "query index timeout"` |
| `dst=self`，`uint64_fileid=343328515` | **`result=0`**，`original_down_para=/download?appid=1407&fileid=…&rkey=…&spec=0`，`domains=[gchat.qpic.cn]` |
| `dst=发件人 uin` | `result=199 "para error"` |
| 只给 pic_up_timestamp、不给 fileid | 206 |

- 回执里的 rkey 与消息里那条**不同** ⇒ 服务端确实重签。
- `curl "https://gchat.qpic.cn$para"` → `200`，`1140454` 字节，`GIF89a` 开头，与消息里 `uint32_file_size` 完全一致。

## 3. 实现（四层）

1. **内核取字段**：`Qq8ImageElem` 新增 `fileId`（`Qq8Pb.intAt(cf, 7)`）。以前用 `textAt` 读同一个字段——它是 varint，恒为 null，所以「刷新」永远拿不到 fileid 只会回 206。
2. **内核拼地址**：`Qq8ImageDown.downloadUrlOf(reply, {picType})` —— para 优先配 `domains` 走 `https://`，没域名退回 `http://{ip}:{port}`，都没有返回 null（**不猜地址**）。
3. **传输层兜底**：`MediaCache.ensure(refreshUrl:)` —— 只在候选全挂且最坏分类属于 `expired`/`missing` 时调一次 `refreshUrl()`，拿到的新地址若不是老地址就再取一次。**只换一次**，服务端仍不肯给就交给负缓存按 TTL 拒绝（防打转）。
4. **接线**：`ImageSegment` 带上 `md5/fileId/groupCode` → `ChatStore.imageUrlResolver` → `Qq8LoginService.resolveGroupImageUrl()` 发 `ImgStore.GroupPicDown` → 回执转 URL。

细节决策：

- **只有前台的 `ensureMedia` 换链**，后台 `_prefetchMedia` 不换。否则打开一个会话就会为整屏死链各发一个 WUP 请求。
- 换链需要 `md5 + fileId + groupCode` 三者齐全，缺一项直接返回 null，宁可显示「图片已失效 · 点按重试」也不发注定回 206 的包。
- `dst_uin` 必须是自己（`s.uin`），发件人 uin 会回 199。
- 换链失败/异常一律静默返回 null，绝不进登录状态机。

## 4. 离线验证

| 自测 | 覆盖 | 结果 |
| --- | --- | --- |
| `tool/qq8_image_down_selftest.dart` | `downloadUrlOf` 7 项：域名优先 https、无域名退 ip:port、para 无前导 / 自动补、无 para → null、无域名无 ip → null、picType 选对 para、picType 不匹配 → null | 45 通过 0 失败 |
| `tool/media_cache_selftest.dart` | 换链钩子 11 项：过期后换新地址落地、只调一次、成功后清负缓存、原样返回时不重试、返回 null 时只调一次、失败仍记 expired 负缓存、主链 rejected + 兜底 404 也换链、不传 refreshUrl 行为不变 | 99 通过 0 失败 |
| `tool/chat_store_media_selftest.dart` | 接线 9 项：过期直链换链后落盘、回调参数（群号/md5/fileid）、缺 fileId 不换链、私聊图不换链 | 23 通过 0 失败 |

门禁：`dart analyze lib` No issues；`tool/run_all_selftests.sh` pass=55 fail=0；`flutter test` 见提交记录。

## 5. 四态口径

- **已实现**：群图直链过期后凭 fileid 换新链并落盘（前台可见时）。
- **离线已验证**：上面三张表。
- **真机已验证**：见第 6 节。
- **明确不支持**：私聊图的对应通道（`LongConn.OffPicDown`，`cmd0x352`）未实现——私聊图过期仍显示「图片已失效 · 点按重试」；服务端已经删掉的图，任何客户端都取不回来。

## 6. 真机验证

设备：HA2CSJR5 / 25091RP04C / Android 16（API 36）；包 `com.example.qqclient`；release `app-arm64-v8a-release.apk` 21.6MB，`adb install -r` 保数据安装。

### 6.1 触发条件必须包含 rejected（不是只有 expired）

第一轮把测试消息的直链 rkey 改成 `BADBAD…`，服务端回的不是「过期」而是：

```
kind=rejected status=400 retcode=-5503011 msg=invalid rkey
```

即 **rkey 被改坏/失效时服务端报 `invalid rkey`（-5503011），归 rejected 而不归 expired**。因此换链触发条件定为主链分类 ∈ {expired, missing, rejected}——三者的共同点是「这条链不能用了」，而兜底地址失败不说明链路问题，所以只看主链（`candidateIndex == 1` 的那次）分类。

### 6.2 全链路实证（23:20:31）

前置：用 `tool/tmp/list_group_pics.dart`（一次性只读诊断脚本）向服务端拉群图元数据，拿到 md5↔fileid 映射：

```
seq=59192 md5=8532b4181a5040aed6d8c73448cfc0ee fileid=868376579 size=6718
```

再往群 486045673 的历史 jsonl 注入一条带 `md5/fileId/groupCode` 的图片消息（id 前缀 `INJECTPICDOWN`，直链用已 404 的 `gchatpic_new/0/0-0-8532B4181A5040AED6D8C73448CFC0EE/0`），重启应用。日志（`/data/user/0/com.example.qqclient/files/logs/qqclient-2026-10-31.log` 第 8878/8879 行）：

```
23:20:30.824 W/媒体缓存 媒体下载失败 key=img:8532b4181a5040aed6d8c73448cfc0ee6718-199-200.jpg cat=photos cand=https://gchat.qpic.cn/gchatpic_new/0/0-0-8532B4181A5040AED6D8C73448CFC0EE/0 try=1 kind=missing status=404 retcode=null msg=null 221ms
23:20:31.004 I/QQ8SVC 群图换链成功 gid=486045673 md5=8532b4181a5040aed6d8c73448cfc0ee → https://gchat.qpic.cn/download?appid=1407&fileid=EhRdOC2_n79gtClJ7X2Rotz9Kw4UNxi-NCD_CiiDmeyHlOSXAzIEcHJvZFCAvaMBWhCChBhPHSB4DoQ_VrThp5cLegIZuoIBAmd6&rkey=CAISONPsN0nSR8aLIBBThW1JhoIPCu32Mm3a36baGidlz3vLSls3Jn1ai1TmFM3K1BFpsoHnmPT6pBlX&spec=0
23:20:31.092 I/媒体缓存 媒体换链成功 key=img:8532b4181a5040aed6d8c73448cfc0ee6718-199-200.jpg cat=photos bytes=6718 87ms
```

落盘确认（大小与元数据里的 `size=6718` 完全一致）：

```
/data/user/0/com.example.qqclient/files/accounts/3880159487/media/photos/6be92ca865892370197ba1e89eda1520bd1022f4003f95ad4867ecc2a40b8ec9   6718  23:20
```

耗时 87ms（换链包 180ms 内往返），调用链是 `_ImageBlock._scheduleEnsure → ChatStore.ensureMedia → MediaCache._download → refreshUrl() → resolveGroupImageUrl → ImgStore.GroupPicDown → downloadUrlOf`。

注入的两条 `INJECTPICDOWN` 消息在 ChatStore 重写 jsonl 时自然消失（`grep -c INJECTPICDOWN` = 0），设备数据保持干净。

### 6.3 这次没验到的

- **老消息**：本次改造之前落盘的 jsonl 里根本没有 `md5/fileId` 字段，`_refresherFor` 拿到 null 就不换链 → 那些老图仍然显示「图片已失效 · 点按重试」。只有「改造后新收到的、以及改造后重新拉到的历史」才带 fileId。这是数据层面的既成事实，不是逻辑漏洞：要救老图，得另做一次「按 msgId 回服务端重查图片元数据」的迁移。
- **私聊图**：`LongConn.OffPicDown`（cmd0x352）未实现，私聊过期图仍打不开。
