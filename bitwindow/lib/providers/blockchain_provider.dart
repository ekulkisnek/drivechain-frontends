import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';
import 'package:sail_ui/env.dart';
import 'package:sail_ui/gen/bitcoin/bitcoind/v1alpha/bitcoin.pb.dart';
import 'package:sail_ui/gen/bitwindowd/v1/bitwindowd.pb.dart';
import 'package:sail_ui/sail_ui.dart';

/// Merge the first page of tip blocks from [listBlocks] into the existing list.
/// Returns the new list and height set. Pure so unit tests can drive it without
/// standing up RPC / GetIt (#1861).
(List<Block> blocks, Set<int> heights) mergeTipBlocks(
  List<Block> existing,
  Set<int> existingHeights,
  List<Block> tipPage,
) {
  if (existing.isEmpty) {
    return (List<Block>.from(tipPage), tipPage.map((b) => b.height).toSet());
  }
  final toAdd = tipPage.where((b) => !existingHeights.contains(b.height)).toList();
  if (toAdd.isEmpty) {
    return (existing, existingHeights);
  }
  final heights = {...existingHeights, ...toAdd.map((b) => b.height)};
  final blocks = [...toAdd, ...existing]..sort((a, b) => b.height.compareTo(a.height));
  return (blocks, heights);
}

class BlockchainProvider extends ChangeNotifier implements NetworkScoped {
  @override
  Future<void> onNetworkChanged() async {
    clear();
  }

  Logger get log => GetIt.I.get<Logger>();
  BitwindowRPC get bitwindowd => GetIt.I.get<BitwindowRPC>();
  OrchestratorRPC get _orchestrator => GetIt.I.get<OrchestratorRPC>();
  BitcoindConnection get mainchain => GetIt.I.get<BitcoindConnection>();
  EnforcerRPC get enforcer => GetIt.I.get<EnforcerRPC>();
  SyncProvider get syncProvider => GetIt.I.get<SyncProvider>();

  // raw data go here
  List<Peer> peers = [];
  List<Block> blocks = [];
  List<RecentTransaction> recentTransactions = [];

  String? error;
  bool hasMoreBlocks = true;
  bool isLoadingMoreBlocks = false;
  Set<int> loadedBlockHeights = {};

  Duration _currentInterval = const Duration(seconds: 5);
  bool _isFetching = false;
  Timer? _fetchTimer;

  BlockchainProvider() {
    _startFetchTimer();
    mainchain.addListener(fetch);
    bitwindowd.addListener(fetch);
    enforcer.addListener(fetch);
    syncProvider.addListener(notifyListeners);
  }

  // call this function from anywhere to refetch blockchain info
  Future<void> fetch() async {
    if (!bitwindowd.connected || _isFetching) return;
    _isFetching = true;

    try {
      final newPeers = (await _orchestrator.bitcoind.getPeerInfo(GetPeerInfoRequest())).peers;
      final newTXs = await bitwindowd.bitwindowd.listRecentTransactions();
      final (newBlocks, hasMore) = await bitwindowd.bitwindowd.listBlocks();

      final (mergedBlocks, mergedHeights) = mergeTipBlocks(blocks, loadedBlockHeights, newBlocks);
      final blocksChanged = !listEquals(blocks, mergedBlocks);

      if (_dataHasChanged(newPeers, newTXs, blocksChanged)) {
        peers = newPeers;
        recentTransactions = newTXs;
        if (blocksChanged) {
          blocks = mergedBlocks;
          loadedBlockHeights = mergedHeights;
        }
        hasMoreBlocks = hasMore;
        error = null;
        notifyListeners();
      }
    } catch (e) {
      error = e.toString();
    } finally {
      _isFetching = false;
    }
  }

  bool _dataHasChanged(
    List<Peer> newPeers,
    List<RecentTransaction> newTXs,
    bool blocksChanged,
  ) {
    if (!listEquals(peers, newPeers)) {
      return true;
    }

    if (!listEquals(recentTransactions, newTXs)) {
      return true;
    }

    if (blocksChanged) {
      return true;
    }

    return false;
  }

  void _startFetchTimer() {
    fetch();

    if (Environment.isInTest) {
      return;
    }

    void tick() async {
      try {
        await fetch();
        // During IBD we should be pretty spammy to get up-to-date info all the time
        // After IBD however we can check less frequently, so as soon as IBD is done
        // we check every 5 seconds.

        // Check if we need to change the interval
        // SyncProvider is the source of truth for "are we still catching up";
        // ride its `isSynced` so we drop to a calmer cadence the moment all
        // tracked daemons report synced.
        final newInterval = syncProvider.isSynced ? const Duration(seconds: 5) : const Duration(milliseconds: 200);
        if (newInterval != _currentInterval) {
          // IBD-status changed!
          _currentInterval = newInterval;
          _fetchTimer?.cancel();
          _fetchTimer = Timer.periodic(_currentInterval, (_) => tick());
        }
      } catch (e) {
        // do nothing, swallov!
      }
    }

    _fetchTimer = Timer.periodic(_currentInterval, (_) => tick());
  }

  /// Wipe cached state on network swap so the UI stops showing the previous
  /// network's data while the next fetch repopulates from new bitwindowd.
  void clear() {
    peers = [];
    blocks = [];
    recentTransactions = [];
    loadedBlockHeights = {};
    hasMoreBlocks = true;
    isLoadingMoreBlocks = false;
    error = null;
    notifyListeners();
  }

  Future<void> loadMoreBlocks() async {
    if (!hasMoreBlocks || isLoadingMoreBlocks) return;

    isLoadingMoreBlocks = true;
    try {
      final lastBlock = blocks.last;
      final (moreBlocks, hasMore) = await bitwindowd.bitwindowd.listBlocks(
        startHeight: lastBlock.height - 1,
      );

      // Filter out blocks we've already loaded
      final newBlocks = moreBlocks.where((b) => !loadedBlockHeights.contains(b.height)).toList();
      if (newBlocks.isEmpty) {
        hasMoreBlocks = false;
        return;
      }

      // Add new block heights to our set
      loadedBlockHeights.addAll(newBlocks.map((b) => b.height));

      // Sort all blocks by height in descending order (newest to oldest)
      blocks = [...blocks, ...newBlocks]..sort((a, b) => b.height.compareTo(a.height));
      hasMoreBlocks = hasMore;
      notifyListeners();
    } finally {
      isLoadingMoreBlocks = false;
    }
  }

  @override
  void dispose() {
    _fetchTimer?.cancel();
    _fetchTimer = null;
    mainchain.removeListener(fetch);
    bitwindowd.removeListener(fetch);
    enforcer.removeListener(fetch);
    syncProvider.removeListener(notifyListeners);
    super.dispose();
  }
}
