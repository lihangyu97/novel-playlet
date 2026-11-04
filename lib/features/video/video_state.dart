export '../../app/feed/feed_state.dart'
    show FeedMode, FeedState, describeFeedError;

import '../../app/feed/feed_state.dart';
import '../../data/models/video_series.dart';

/// 短剧推荐列表状态。分页/去重逻辑在通用 [FeedState]，这里只固定元素类型。
typedef VideoFeedState = FeedState<VideoSeries>;

String describeVideoError(Object error) => describeFeedError(error);
