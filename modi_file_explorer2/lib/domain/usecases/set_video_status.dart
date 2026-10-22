import '../entities/video_index_record.dart';
import '../entities/video_status_target.dart';
import '../repositories/video_repository.dart';

class SetVideoStatus {
  const SetVideoStatus(this._repository);

  final VideoRepository _repository;

  Future<VideoStatusUpdateResult> call({
    required List<VideoStatusTarget> targets,
    required VideoStatus status,
  }) => _repository.setStatuses(targets: targets, status: status);
}
