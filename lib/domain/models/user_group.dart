class GroupMember {
  const GroupMember({
    required this.userId,
    required this.username,
    required this.email,
  });
  final String userId, username, email;
  String get label => username.isNotEmpty ? username : email;
  factory GroupMember.fromJson(Map<String, Object?> json) => GroupMember(
    userId: json['UserId'] as String,
    username: json['Username'] as String? ?? '',
    email: json['Email'] as String? ?? '',
  );
}

class UserGroup {
  const UserGroup({
    required this.groupId,
    required this.ownerId,
    required this.title,
    this.members = const [],
  });
  final String groupId, ownerId, title;
  final List<GroupMember> members;
  factory UserGroup.fromJson(Map<String, Object?> json) => UserGroup(
    groupId: json['GroupId'] as String,
    ownerId: json['UserId'] as String,
    title: json['Title'] as String? ?? '',
    members: [
      for (final member in (json['Users'] as List? ?? []))
        GroupMember.fromJson(Map<String, Object?>.from(member as Map)),
    ],
  );
}
