/// 媒体引用推导自测（纯 Dart，不依赖 Flutter 引擎）
///
/// 运行：dart run tool/media_refs_selftest.dart
///
/// 这一层最容易出错的不是"能不能推出来"，而是**推出来的键在下次启动后还
/// 一样吗**。键不稳定 = 每次冷启动重下一遍，用户流量白烧、缓存永远命不中。
/// 所以这里的用例按"哪些字段稳定"来组织，而不是按 Segment 类型。
// ignore_for_file: avoid_print, avoid_relative_lib_imports
library;

import '../lib/client_api/media_refs.dart';
import '../lib/client_api/segment.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    print('  [OK] $name');
  } else {
    _failed++;
    print('  [FAIL] $name${detail == null ? '' : ' -> $detail'}');
  }
}

void main() {
  print('=== 媒体引用推导自测 ===');

  // ---------------------------------------------------------------
  print('\n[图片] 键的选择');
  {
    // QQ 的典型形态：file 是"文件名"，url 是带 rkey 的直链。
    final qq = ImageSegment(
      '6B4F2A1C8D3E5F70A9B1C2D3E4F50617.jpg',
      url: 'https://gchat.qpic.cn/gchatpic_new/0/0-0-6B4F2A1C/0?term=2&rkey=abc',
    );
    final ref = mediaRefOf(qq);
    check('有 file 时键用 file', ref?.key == 'img:6B4F2A1C8D3E5F70A9B1C2D3E4F50617.jpg',
        ref?.key);
    check('键里不含 url（直链会变）', !(ref?.key ?? '').contains('rkey'), ref?.key);
    check('分类是 photos', ref?.category == 'photos', ref?.category);
    check('地址用 url', ref?.url == qq.url, ref?.url);

    // 同样的图换一批 rkey（模拟几天后再打开）
    final again = ImageSegment(
      '6B4F2A1C8D3E5F70A9B1C2D3E4F50617.jpg',
      url: 'https://gchat.qpic.cn/gchatpic_new/0/0-0-6B4F2A1C/0?term=5&rkey=ZZZ',
    );
    check('直链换了、键不变（这是缓存能命中的前提）',
        mediaRefOf(again)?.key == ref?.key);

    // 只有直链没有 file
    final onlyUrl = ImageSegment(
      '',
      url: 'https://c2cpicdw.qpic.cn/offpic_new/0//0?term=2',
    );
    final r2 = mediaRefOf(onlyUrl);
    check('没有 file 时退回 url 做键',
        r2?.key == 'img:https://c2cpicdw.qpic.cn/offpic_new/0//0?term=2', r2?.key);

    // 两者都没有
    check('既无 file 又无 url -> null', mediaRefOf(const ImageSegment('')) == null);
  }

  // ---------------------------------------------------------------
  print('\n[图片] 本地路径不能被当成缓存键');
  {
    // OneBot 后端有时给的是后端主机上的绝对路径。
    final unixPath = ImageSegment(
      '/root/napcat/data/image/abc123.image',
      url: 'https://example.com/x',
    );
    final r = mediaRefOf(unixPath);
    check('Unix 绝对路径的 file 不拿来做键',
        !(r?.key ?? '').startsWith('img:/root/'), r?.key);
    check('退回 url 做键', r?.key == 'img:https://example.com/x', r?.key);

    final winPath = ImageSegment(r'C:\napcat\data\abc.image');
    final r2 = mediaRefOf(winPath);
    check('Windows 路径既是 file 又是地址',
        r2 != null && r2.url == r'C:\napcat\data\abc.image', r2?.url);
    check('Windows 路径做键（没有别的可用）',
        r2?.key == r'img:C:\napcat\data\abc.image', r2?.key);

    // 相对路径也按路径处理：有 url 时键用 url，不拿路径。
    final relative = ImageSegment('./data/abc.image', url: 'https://x/rel');
    check('相对路径不拿来做键（有 url 时）',
        mediaRefOf(relative)?.key == 'img:https://x/rel',
        mediaRefOf(relative)?.key);
  }

  // ---------------------------------------------------------------
  print('\n[语音 / 视频 / 文件] 分类与键');
  {
    final voice = RecordSegment('abc.amr', url: 'https://x/v', seconds: 3);
    final rv = mediaRefOf(voice);
    check('语音分类 voices', rv?.category == 'voices', rv?.category);
    check('语音键带 voice 前缀', rv?.key == 'voice:abc.amr', rv?.key);

    final video = VideoSegment('v.mp4', url: 'https://x/v.mp4', seconds: 5);
    final rvv = mediaRefOf(video);
    check('视频分类 videos', rvv?.category == 'videos', rvv?.category);
    check('视频键带 video 前缀', rvv?.key == 'video:v.mp4', rvv?.key);

    final file = FileSegment('a.pdf', fileId: 'fid-1', size: 100);
    final rf = mediaRefOf(file);
    check('文件分类 files', rf?.category == 'files', rf?.category);
    check('文件键带 file 前缀', rf?.key == 'file:a.pdf', rf?.key);
    check('FileSegment 没有 url 时地址为空（当前无法下载）', rf?.url == '', rf?.url);
  }

  // ---------------------------------------------------------------
  print('\n[前缀隔离] 不同类型的同名文件不能撞键');
  {
    final img = ImageSegment('same.bin', url: 'https://x/1');
    final vid = VideoSegment('same.bin', url: 'https://x/2');
    check('图片与视频同名不撞键', mediaRefOf(img)?.key != mediaRefOf(vid)?.key,
        '${mediaRefOf(img)?.key} vs ${mediaRefOf(vid)?.key}');
  }

  // ---------------------------------------------------------------
  print('\n[分类必须在 mediaCategories 内]');
  {
    const allowed = {'photos', 'videos', 'files', 'voices', 'other'};
    final all = <Segment>[
      const ImageSegment('a.jpg'),
      const RecordSegment('b.amr'),
      const VideoSegment('c.mp4'),
      const FileSegment('d.pdf'),
    ];
    for (final seg in all) {
      final cat = mediaRefOf(seg)?.category;
      check('${seg.runtimeType} 的分类 $cat 合法', allowed.contains(cat), cat);
    }
  }

  // ---------------------------------------------------------------
  print('\n[候选地址] 直链失效后还有没有第二选择');
  {
    // QQ 图片的 file 前 32 位就是 md5 —— 据此拼 md5 兜底直链。
    const md5 = '3a2091fc7e3b9cce2e001827817784e8';
    final img = ImageSegment(
      '${md5}79147-864-1920.jpg',
      url: 'https://gchat.qpic.cn/download?appid=1407&fileid=x&rkey=AAA',
    );
    final ref = mediaRefOf(img);
    check('有备选地址', (ref?.altUrls.length ?? 0) == 1, '${ref?.altUrls}');
    check(
      '备选是按 MD5 大写拼的 gchatpic_new',
      ref?.altUrls.first ==
          'https://gchat.qpic.cn/gchatpic_new/0/0-0-${md5.toUpperCase()}/0',
      ref?.altUrls.first,
    );
    check('首选仍是消息里带的直链',
        ref?.candidates.first == img.url, ref?.candidates.first);
    check('候选里含两项', ref?.candidates.length == 2, '${ref?.candidates}');

    // 首选与备选恰好相同时不能重复下载同一个地址。
    final dup = ImageSegment(
      '${md5}1-1-1.jpg',
      url: 'https://gchat.qpic.cn/gchatpic_new/0/0-0-${md5.toUpperCase()}/0',
    );
    check('首选与备选相同时去重', mediaRefOf(dup)?.candidates.length == 1,
        '${mediaRefOf(dup)?.candidates}');

    // 不是 QQ 命名（OneBot 给的别的名字）就不该瞎拼 md5 直链。
    check('非 QQ 文件名不生成备选',
        mediaRefOf(const ImageSegment('abc.image'))?.altUrls.isEmpty ?? false);
    check(
        '语音段没有备选',
        mediaRefOf(const RecordSegment('x.amr', url: 'http://a/b'))
                ?.altUrls
                .isEmpty ??
            false);
  }

  // ---------------------------------------------------------------
  print('\n[坏地址] 历史消息里存着拼接错误的主机名');
  {
    // 真机踩过的形态：域名后面直接接 query，主机名被污染成
    // `gchat.qpic.cn&rkey=...`，DNS 根本解析不出来。
    const broken = 'https://gchat.qpic.cn&rkey=CAMSOLgthq&spec=0';
    check('坏地址被判为不可用', !usableMediaUrl(broken));
    check('正常地址可用',
        usableMediaUrl('https://gchat.qpic.cn/download?appid=1407'));
    check('空地址不算坏', usableMediaUrl('') && usableMediaUrl(null));
    check('本地路径可用', usableMediaUrl('/data/user/0/x/y.jpg'));

    // 坏地址要被丢掉，让候选链走到 md5 兜底。
    const md5b = 'faf02a8883f8ac80bc4538f6ef9e90ec';
    final legacy = ImageSegment('${md5b}1-1-1.jpg', url: broken);
    final ref = mediaRefOf(legacy);
    check('坏地址不进候选', !(ref?.candidates.contains(broken) ?? true),
        '${ref?.candidates}');
    check('坏地址时仍能靠 md5 兜底下', (ref?.candidates.length ?? 0) == 1,
        '${ref?.candidates}');
  }

  // ---------------------------------------------------------------
  print('\n[非媒体段]');
  {
    check('文本段不缓存', mediaRefOf(const TextSegment('hi')) == null);
    check('表情段不缓存', mediaRefOf(const FaceSegment('1')) == null);
    check('segmentHasMedia(图片)', segmentHasMedia(const ImageSegment('a.jpg')));
    check('segmentHasMedia(文本) 为 false',
        !segmentHasMedia(const TextSegment('hi')));
  }

  print('\n=== 结果: $_passed 通过, $_failed 失败 ===');
}
