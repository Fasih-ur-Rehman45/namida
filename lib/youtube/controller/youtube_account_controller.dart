// ignore_for_file: constant_identifier_names

import 'dart:async';

import 'package:namico_login_manager/namico_login_manager.dart';
import 'package:namico_subscription_manager/class/supabase_sub.dart';
import 'package:namico_subscription_manager/class/support_tier.dart';
import 'package:namico_subscription_manager/core/enum.dart';
import 'package:namico_subscription_manager/namico_subscription_manager.dart';
import 'package:youtipie/class/youtipie_feed/channel_info_item.dart';
import 'package:youtipie/core/enum.dart';
import 'package:youtipie/managers/acount_manager.dart';
import 'package:youtipie/youtipie.dart' hide logger;

import 'package:namida/class/route.dart';
import 'package:namida/controller/connectivity.dart';
import 'package:namida/controller/logs_controller.dart';
import 'package:namida/controller/navigator_controller.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/core/translations/language.dart';
import 'package:namida/core/utils.dart';
import 'package:namida/youtube/pages/user/youtube_account_manage_page.dart';

class YoutubeAccountController {
  const YoutubeAccountController._();

  static final current = YoutiPie.cookies;
  static final membership = _CurrentMembership._();

  static RxBaseCore<YoutiLoginProgress?> get signInProgress => _signInProgress;
  static final _signInProgress = Rxn<YoutiLoginProgress>();

  /// functions to be called after stable connection is obtained.
  static final _pendingRequests = <String, Future<void> Function()>{};

  /// By default, all account operations need membership, these are exceptions.
  static const _operationNeedsMembership = <YoutiPieOperation, bool>{
    YoutiPieOperation.changeVideoLikeStatus: false,
    YoutiPieOperation.addVideoToHistory: false,
    YoutiPieOperation.fetchUserPlaylists: false,
    YoutiPieOperation.fetchUserPlaylistsNext: false,
    YoutiPieOperation.getPlaylistsForVideo: false,
    YoutiPieOperation.getPlaylistEditInfo: false,
    YoutiPieOperation.addRemoveVideosPlaylist: false,
    YoutiPieOperation.createPlaylist: false,
  };

  static const _operationHasErrorPage = <YoutiPieOperation, bool>{
    YoutiPieOperation.fetchFeed: true,
    YoutiPieOperation.fetchNotifications: true,
    YoutiPieOperation.fetchHistory: true,
    YoutiPieOperation.fetchUserPlaylists: true,
    YoutiPieOperation.fetchUserChannels: true,
  };

  static String formatMembershipErrorMessage(YoutiPieOperation? operation, MembershipType? ms) {
    final currentMSMessage = lang.YOUR_CURRENT_MEMBERSHIP_IS.replaceFirst('_NAME_', "`${ms?.name ?? MembershipType.unknown.name}`");
    if (operation == null) return currentMSMessage;

    final operationMessage = lang.OPERATION_REQUIRES_MEMBERSHIP.replaceFirst('_OPERATION_', '`${operation.name}`').replaceFirst('_NAME_', '`${MembershipType.cutie.name}`');
    return '$operationMessage. $currentMSMessage';
  }

  static bool operationBlockedByMembership(YoutiPieOperation operation, MembershipType? ms) {
    final needsMembership = _operationNeedsMembership[operation] ?? true;
    if (needsMembership) {
      if (ms == null || ms.index < MembershipType.cutie.index) {
        return true;
      }
    }
    return false;
  }

  static bool _canShowOperationError(YoutiPieOperation operation) {
    if (_operationHasErrorPage[operation] == true) return false;
    return true;
  }

  static void initialize() {
    current.canAddMultiAccounts = false;

    NamicoSubscriptionManager.initialize(dataDirectory: AppDirs.YOUTIPIE_DATA);

    NamicoSubscriptionManager.onError = (message, e, st) {
      _showError(message, exception: e, manageSubscriptionButton: true, messageAsTitle: true);
      logger.error(message, e: e, st: st);
    };

    YoutiPie.canExecuteOperation = (operation) {
      if (operation.requiresAccount) {
        if (current.activeAccountChannel.value == null) {
          // -- no account
          if (_canShowOperationError(operation)) {
            _showError(lang.OPERATION_REQUIRES_ACCOUNT.replaceFirst('_NAME_', '`${operation.name}`'), manageAccountButton: true);
          }
          return false;
        } else {
          final ms = membership.userMembershipTypeGlobal.value;
          if (operationBlockedByMembership(operation, ms)) {
            // -- has account but no membership
            if (_canShowOperationError(operation)) {
              _showError(
                formatMembershipErrorMessage(operation, ms),
                manageSubscriptionButton: true,
              );
            }
            return false;
          }
        }
      }
      return true;
    };

    YoutiPie.onOperationFailNoAccount = (operation) {
      if (current.activeAccountChannel.value == null) {
        if (_canShowOperationError(operation)) {
          _showError(lang.OPERATION_REQUIRES_ACCOUNT.replaceFirst('_NAME_', '`${operation.name}`'), manageAccountButton: true);
        }
        return true;
      }
      return false;
    };

    final patreonSupportTier = NamicoSubscriptionManager.patreon.getUserSupportTierInCacheValid();
    if (patreonSupportTier != null) {
      final ms = patreonSupportTier.toMembershipType();
      membership.userPatreonTier.value = patreonSupportTier;
      membership.userMembershipTypePatreon.value = patreonSupportTier.toMembershipType();
      membership._updateGlobal(ms);
    } else {
      _pendingRequests['patreon'] = () async => await membership.checkPatreon(showError: false);
    }

    final supasub = NamicoSubscriptionManager.supabase.getUserSubInCacheValid();
    if (supasub != null) {
      final ms = supasub.toMembershipType();
      membership.userSupabaseSub.value = supasub;
      membership.userMembershipTypeSupabase.value = supasub.toMembershipType();
      membership._updateGlobal(ms);
    } else {
      final info = NamicoSubscriptionManager.supabase.getUserSubInCache();
      if (info != null) {
        final uuid = info.uuid;
        final email = info.email;
        if (uuid != null && email != null) {
          _pendingRequests['supabase'] = () async => await membership.checkSupabase(uuid, email);
        }
      }
    }
    _executePendingRequests();
  }

  static Future<void> _executePendingRequests() async {
    if (_pendingRequests.isEmpty) return;
    if (ConnectivityController.inst.hasConnection) {
      _executePendingRequestsImmediate();
    } else {
      ConnectivityController.inst.registerOnConnectionRestored(_executePendingRequestsImmediate);
    }
  }

  static Future<void> _executePendingRequestsImmediate() async {
    final copy = Map<String, Future<void> Function()>.from(_pendingRequests);
    for (final e in copy.entries) {
      e.value().then((value) {
        _pendingRequests.remove(e.key);
        if (_pendingRequests.isEmpty) {
          ConnectivityController.inst.removeOnConnectionRestored(_executePendingRequestsImmediate);
        }
      }).catchError((_) {});
    }
  }

  static bool _checkCanSignIn() {
    final userMembershipType = membership.userMembershipTypeGlobal.value ?? MembershipType.unknown;

    if (userMembershipType == MembershipType.owner) {
      if (current.canAddMultiAccounts != true) {
        _showInfo('‧₊˚❀༉‧₊˚ welcome boss ‧₊˚❀༉‧₊˚');
        current.canAddMultiAccounts = true;
      }
      return true;
    }

    bool canSignIn = false;
    final accounts = current.signedInAccounts.value;
    if (accounts.isNotEmpty) {
      if (userMembershipType == MembershipType.pookie || userMembershipType == MembershipType.patootie) {
        canSignIn = true;
        current.canAddMultiAccounts = true;
      } else {
        _showError(
          '${lang.MEMBERSHIP_YOU_NEED_MEMBERSHIP_OF_TO_ADD_MULTIPLE_ACCOUNTS.replaceFirst('_NAME1_', '`${MembershipType.pookie.name}`').replaceFirst('_NAME2_', '`${MembershipType.patootie.name}`')}. ${lang.YOUR_CURRENT_MEMBERSHIP_IS.replaceFirst('_NAME_', "`${userMembershipType.name}`")}',
          manageSubscriptionButton: true,
        );
      }
    } else {
      canSignIn = true;
      current.canAddMultiAccounts = false;

      // -- this was if we didnt allow sign in before membership
      // if (userMembershipType == MembershipType.cutie) {
      //   canSignIn = true;
      //   current.canAddMultiAccounts = false;
      // } else {
      // _showError(
      //   "${lang.YOUR_CURRENT_MEMBERSHIP_IS.replaceFirst('_NAME_', "`${userMembershipType.name}`")}",
      //   manageSubscriptionButton: true,
      // );
      // }
    }
    return canSignIn;
  }

  static Future<ChannelInfoItem?> _youtubeSignInButton({
    required LoginPageConfiguration pageConfig,
    required bool forceSignIn,
    required void Function(YoutiLoginProgress progress) onProgress,
  }) async {
    if (_checkCanSignIn()) {
      final signedInChannel = await YoutiAccountManager.signIn(
        pageConfig: pageConfig,
        onProgress: onProgress,
        forceSignIn: forceSignIn,
      );
      return signedInChannel;
    } else {
      return null;
    }
  }

  static void _showError(String msg, {Object? exception, bool manageSubscriptionButton = false, bool manageAccountButton = false, bool messageAsTitle = false}) {
    String title = lang.ERROR;
    if (exception != null) title += ': $exception';

    if (messageAsTitle) {
      final tempTitle = title;
      title = msg;
      msg = tempTitle;
    }

    snackyy(
      message: msg,
      title: title,
      isError: true,
      displayDuration: SnackDisplayDuration.long,
      button: manageSubscriptionButton
          ? (
              lang.MANAGE,
              const YoutubeManageSubscriptionPage().navigate,
            )
          : manageAccountButton
              ? (
                  lang.SIGN_IN,
                  const YoutubeAccountManagePage().navigate,
                )
              : null,
    );
  }

  static void _showInfo(String msg, {String? title}) {
    snackyy(message: msg, title: title ?? '', displayDuration: SnackDisplayDuration.long);
  }

  static Future<ChannelInfoItem?> signIn({required LoginPageConfiguration pageConfig, required bool forceSignIn}) async {
    void onProgress(YoutiLoginProgress p) {
      _signInProgress.value = p;
      if (p == YoutiLoginProgress.canceled) {
        _showInfo(lang.SIGN_IN_CANCELED);
      } else if (p == YoutiLoginProgress.failed) {
        _showError(lang.SIGN_IN_FAILED);
      }
    }

    final res = await _youtubeSignInButton(pageConfig: pageConfig, forceSignIn: forceSignIn, onProgress: onProgress);
    _signInProgress.value = null;
    return res;
  }

  static void signOut({required ChannelInfoItem userChannel}) {
    YoutiPie.cookies.signOut(userChannel);
  }

  static void setAccountActive({required ChannelInfoItem userChannel}) {
    YoutiPie.cookies.setAccount(userChannel);
  }

  static void setAccountAnonymous() {
    YoutiPie.cookies.setAnonymous();
  }
}

class _CurrentMembership {
  _CurrentMembership._();

  String? get getUsernameGlobal {
    String? name = userSupabaseSub.value?.name;
    if (name == null || name.isEmpty) name = userPatreonTier.value?.userName;
    return name;
  }

  final userSupabaseSub = Rxn<SupabaseSub>();
  final userPatreonTier = Rxn<SupportTier>();

  final userMembershipTypeGlobal = Rxn<MembershipType>();
  final userMembershipTypeSupabase = Rxn<MembershipType>();
  final userMembershipTypePatreon = Rxn<MembershipType>();

  Completer<String?>? redirectUrlCompleter;

  void _updateGlobal(MembershipType ms) {
    final current = userMembershipTypeGlobal.value;
    if (current == null || ms.index > current.index) {
      userMembershipTypeGlobal.value = ms;
    }
  }

  Future<void> claimPatreon({required LoginPageConfiguration pageConfig, required SignInDecision signIn}) async {
    redirectUrlCompleter?.completeIfWasnt();
    redirectUrlCompleter = Completer<String?>();
    final tier = await NamicoSubscriptionManager.patreon.getUserSupportTier(
      redirectUrlCompleter: redirectUrlCompleter,
      pageConfig: pageConfig,
      signIn: signIn,
    );
    redirectUrlCompleter = null;

    if (tier == null) {
      YoutubeAccountController._showError(lang.FAILED);
      return;
    }

    if (tier.ammountUSD == null) {
      YoutubeAccountController._showError(lang.MEMBERSHIP_NO_SUBSCRIPTIONS_FOUND_FOR_USER);
      // -- do not return, assign info
    }

    userPatreonTier.value = tier;
    final ms = tier.toMembershipType();
    userMembershipTypePatreon.value = ms;
    _updateGlobal(ms);
  }

  Future<void> checkPatreon({bool showError = true}) async {
    final tier = await NamicoSubscriptionManager.patreon.getUserSupportTierWithoutLogin();
    if (tier == null) {
      if (showError) YoutubeAccountController._showError(lang.MEMBERSHIP_NO_SUBSCRIPTIONS_FOUND_FOR_USER);
      return;
    }
    userPatreonTier.value = tier;
    final ms = tier.toMembershipType();
    userMembershipTypePatreon.value = ms;
    _updateGlobal(ms);
  }

  void signOutPatreon() {
    NamicoSubscriptionManager.cacheManager.deletePatreonCache();
    const ms = MembershipType.unknown;
    userPatreonTier.value = null;
    userMembershipTypePatreon.value = ms;
    _updateGlobal(ms);
  }

  Future<void> checkSupabase(String code, String email) async {
    final deviceId = NamidaDeviceInfo.deviceId;
    final sub = await NamicoSubscriptionManager.supabase.fetchUserValid(
      uuid: code,
      email: email,
      deviceId: deviceId,
    );
    userSupabaseSub.value = sub;
    final ms = sub.toMembershipType();
    userMembershipTypeSupabase.value = ms;
    _updateGlobal(ms);
  }

  Future<void> claimSupabase(String code, String email) async {
    final deviceId = NamidaDeviceInfo.deviceId;
    final sub = await NamicoSubscriptionManager.supabase.claimSubscription(
      uuid: code,
      email: email,
      deviceId: deviceId,
    );
    userSupabaseSub.value = sub;
    final ms = sub.toMembershipType();
    userMembershipTypeSupabase.value = ms;
    _updateGlobal(ms);
  }
}
