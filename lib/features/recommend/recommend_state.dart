export '../../app/feed/feed_state.dart'
    show FeedMode, FeedState, describeFeedError;

import '../../app/feed/feed_state.dart';
import 'recommend_item.dart';

/// 合并推荐页的列表状态。三类卡片统一成 [RecommendItem]，分页/去重逻辑在
/// 通用 [FeedState] 里。
typedef RecommendState = FeedState<RecommendItem>;
