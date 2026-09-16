/// 个人资料模型（存 KV，进 JSON 备份）。
library;

import '../../l10n/app_localizations.dart';

enum ProfileGender {
  unset,
  male,
  female;

  String label(AppLocalizations l10n) {
    switch (this) {
      case ProfileGender.unset:
        return l10n.genderUnset;
      case ProfileGender.male:
        return l10n.genderMale;
      case ProfileGender.female:
        return l10n.genderFemale;
    }
  }

  static ProfileGender fromStorage(String? value) {
    return ProfileGender.values.firstWhere(
      (gender) => gender.name == value,
      orElse: () => ProfileGender.unset,
    );
  }
}

class UserProfile {
  const UserProfile({
    required this.nickname,
    required this.bio,
    required this.avatarDataUrl,
    this.gender = ProfileGender.unset,
    this.birthday = '',
    this.city = '',
    this.occupation = '',
  });

  final String nickname;
  final String bio;
  final String avatarDataUrl;
  final ProfileGender gender;
  final String birthday;
  final String city;
  final String occupation;

  UserProfile copyWith({
    String? nickname,
    String? bio,
    String? avatarDataUrl,
    ProfileGender? gender,
    String? birthday,
    String? city,
    String? occupation,
  }) {
    return UserProfile(
      nickname: nickname ?? this.nickname,
      bio: bio ?? this.bio,
      avatarDataUrl: avatarDataUrl ?? this.avatarDataUrl,
      gender: gender ?? this.gender,
      birthday: birthday ?? this.birthday,
      city: city ?? this.city,
      occupation: occupation ?? this.occupation,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'nickname': nickname,
      'bio': bio,
      'avatarDataUrl': avatarDataUrl,
      'gender': gender.name,
      'birthday': birthday,
      'city': city,
      'occupation': occupation,
    };
  }

  static UserProfile fromJson(Map<String, Object?> json) {
    return UserProfile(
      nickname: json['nickname'] as String? ?? '不白记',
      bio: json['bio'] as String? ?? '完全免费 · 数据自主',
      avatarDataUrl: json['avatarDataUrl'] as String? ?? '',
      gender: ProfileGender.fromStorage(json['gender'] as String?),
      birthday: json['birthday'] as String? ?? '',
      city: json['city'] as String? ?? '',
      occupation: json['occupation'] as String? ?? '',
    );
  }
}
