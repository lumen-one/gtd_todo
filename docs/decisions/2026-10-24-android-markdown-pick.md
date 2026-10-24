# 决定：安卓挑灵感文件自己发 SAF，换来真实路径

记录：2026-10-24
状态：生效中

## 问题

灵感页读写的是 Obsidian 里那篇 Markdown，必须是**同一份文件**。而 file_picker 在安卓侧
挑**文件**时一律先复制再回路径：原件被拷进 `<缓存目录>/file_picker/<毫秒戳>/<文件名>`，
返回的就是这份副本。后果是连着的三件事——输入框里显示 `/data/user/0/…/cache/…`，看着
像选择没生效；编辑写回的是副本，Obsidian 那份永远不动；系统清缓存后灵感页直接空态。

同一个插件挑**目录**却没问题（走 `getFullPathFromTreeUri`，回真实路径），这也是任务目录
一直好好的原因：两条分支的实现根本不同。

## 决定

安卓侧的灵感文件选择走自建 SAF：`ACTION_OPEN_DOCUMENT` 收 URI，把 documentId 换成真实
路径——`com.android.externalstorage` 的 `primary:` 落到 `/storage/emulated/0/`，其他卷落到
`/storage/<卷标>/`；`downloads` 的 `raw:` 前缀剥掉；其余退一步查 `_data` 列。最后
`File(path).canRead()` 验一遍，验不过回落 null（UI 退回手输）。

桌面仍走 file_picker：系统选择器给的就是真实路径，没有这层副本。

## 备选与为什么输

**继续用 file_picker，拿返回的 `name` 自己拼路径。** 输在拼不出目录：返回的只有文件名和
缓存路径，原件住在哪个文件夹一概不知道。

**先挑目录（这条路是通的），再在 App 里列 `.md` 让人选。** 输在多一步，而且只认选中的
那一层：vault 分了子目录就点不下去。

**改存 URI，读写一律走 ContentResolver。** 输在要把 `NotesPort` 从"一个文件路径"改成流式
读写——正文段提取、换行风格保留、frontmatter 保真全得重做一遍。为一个入口改一整层，代价
与收益不成比例。

**只留手输。** 输在人记不住 `/storage/emulated/0/Documents/…` 这一长串；手输留下作兜底就
够了。

## 代价

- **只覆盖能换出路径的 provider**：Obsidian vault 在共享存储上（externalstorage）没问题；
  从"最近"或云盘类服务里挑到的文档换不出来，只能手输。
- **仍然依赖"所有文件访问"**：没有 MANAGE_EXTERNAL_STORAGE 连读都读不了；选择器先申请
  权限，被拒回 null。
- **一个安卓专有的原生分支**：端口签名不变，但 `pickFile` 在安卓与桌面各有一条实现，
  将来加平台要各写一遍。
