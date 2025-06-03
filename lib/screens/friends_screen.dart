import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'friend_events_screen.dart';
import 'chat_screen.dart';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _friends = [];
  List<Map<String, dynamic>> _filteredFriends = [];
  List<Map<String, dynamic>> _friendRequests = [];
  bool _isLoadingFriends = true;
  bool _isLoadingRequests = true;
  String _searchTerm = '';

  @override
  void initState() {
    super.initState();
    _loadData();
    _searchController.addListener(_filterFriends);
  }

  @override
  void dispose() {
    _searchController.removeListener(_filterFriends);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    await _fetchFriends();
    await _fetchFriendRequests();
  }

  void _filterFriends() {
    final searchTerm = _searchController.text.toLowerCase();
    if (searchTerm.isEmpty) {
      setState(() {
        _filteredFriends = _friends;
        _searchTerm = '';
      });
    } else {
      setState(() {
        _searchTerm = searchTerm;
        _filteredFriends = _friends.where((friend) {
          final displayName = friend['displayName']?.toString().toLowerCase() ?? '';
          final email = friend['email']?.toString().toLowerCase() ?? '';
          return displayName.contains(searchTerm) || email.contains(searchTerm);
        }).toList();
      });
    }
  }

  Future<void> _fetchFriends() async {
    setState(() {
      _isLoadingFriends = true;
    });
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _isLoadingFriends = false);
      return;
    }

    try {
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final List<dynamic> friendUids = userDoc.data()?['friendUids'] as List<dynamic>? ?? [];
      List<Map<String, dynamic>> loadedFriends = [];
      for (String uid in friendUids.cast<String>()) {
        final friendDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
        if (friendDoc.exists) {
          loadedFriends.add({
            'uid': uid,
            'displayName': friendDoc.data()?['displayName'],
            'email': friendDoc.data()?['email'],
            'photoURL': friendDoc.data()?['photoURL'],
          });
        }
      }
      if (mounted) {
        setState(() {
          _friends = loadedFriends;
          _filteredFriends = loadedFriends;
          _isLoadingFriends = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingFriends = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching friends: $e')),
        );
      }
    }
  }

  Future<void> _fetchFriendRequests() async {
    setState(() {
      _isLoadingRequests = true;
    });
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _isLoadingRequests = false);
      return;
    }
    try {
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final List<dynamic> requestUids = userDoc.data()?['friendRequests'] as List<dynamic>? ?? [];
      List<Map<String, dynamic>> loadedRequests = [];
      for (String uid in requestUids.cast<String>()) {
        final reqDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
        if (reqDoc.exists) {
          loadedRequests.add({
            'uid': uid,
            'displayName': reqDoc.data()?['displayName'],
            'email': reqDoc.data()?['email'],
            'photoURL': reqDoc.data()?['photoURL'],
          });
        }
      }
      if (mounted) {
        setState(() {
          _friendRequests = loadedRequests;
          _isLoadingRequests = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingRequests = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching friend requests: $e')),
        );
      }
    }
  }

  Future<void> _sendFriendRequest(String email) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final String currentEmail = currentUser.email ?? "";
    if (email.trim().toLowerCase() == currentEmail.toLowerCase()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You cannot add yourself!')),
      );
      return;
    }

    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('email', isEqualTo: email.trim())
        .limit(1)
        .get();

    if (query.docs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User not found with that email.')),
      );
      return;
    }

    final targetUserDoc = query.docs.first;
    final targetUid = targetUserDoc.id;
    final targetUserData = targetUserDoc.data();

    // Check if already friends
    final userDocSnapshot = await FirebaseFirestore.instance.collection('users').doc(currentUser.uid).get();
    final List<dynamic> friendsList = userDocSnapshot.data()?['friendUids'] as List<dynamic>? ?? [];
    if (friendsList.contains(targetUid)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are already friends with this user!')),
      );
      return;
    }

    // Check if request already received from them
    if (_friendRequests.any((req) => req['uid'] == targetUid)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This user has already sent you a friend request. Check your requests.')),
      );
      return;
    }

    // Check if request already sent by you
    final List<dynamic> targetUserFriendRequests = targetUserData['friendRequests'] as List<dynamic>? ?? [];
    if (targetUserFriendRequests.contains(currentUser.uid)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Friend request already sent to this user!')),
      );
      return;
    }

    try {
      await FirebaseFirestore.instance.collection('users').doc(targetUid).update({
        'friendRequests': FieldValue.arrayUnion([currentUser.uid]),
      });
      _searchController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Friend request sent!')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send request: $e')),
      );
    }
  }

  Future<void> _acceptFriendRequest(String requesterUid) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final WriteBatch batch = FirebaseFirestore.instance.batch();
    final currentUserRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
    final requesterRef = FirebaseFirestore.instance.collection('users').doc(requesterUid);

    batch.update(currentUserRef, {
      'friendRequests': FieldValue.arrayRemove([requesterUid]),
      'friendUids': FieldValue.arrayUnion([requesterUid]),
    });

    batch.update(requesterRef, {
      'friendUids': FieldValue.arrayUnion([user.uid]),
    });

    try {
      await batch.commit();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Friend request accepted!')),
      );
      _loadData();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to accept request: $e')),
      );
    }
  }

  Future<void> _rejectFriendRequest(String requesterUid) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'friendRequests': FieldValue.arrayRemove([requesterUid]),
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Friend request rejected.')),
      );
      _fetchFriendRequests();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to reject request: $e')),
      );
    }
  }
  
  Future<void> _removeFriend(String friendUid) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Friend'),
        content: const Text('Are you sure you want to remove this friend?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Remove',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final WriteBatch batch = FirebaseFirestore.instance.batch();
    final currentUserRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
    final friendRef = FirebaseFirestore.instance.collection('users').doc(friendUid);

    batch.update(currentUserRef, {'friendUids': FieldValue.arrayRemove([friendUid])});
    batch.update(friendRef, {'friendUids': FieldValue.arrayRemove([user.uid])});

    try {
      await batch.commit();
      await _deleteChatWithFriend(friendUid);
      await _deleteEventInvitationsForFriend(friendUid);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Friend removed.')),
      );
      _fetchFriends();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to remove friend: $e')),
      );
    }
  }

  Future<void> _deleteChatWithFriend(String friendUid) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    final chatId = [currentUser.uid, friendUid]..sort();
    final chatDocId = chatId.join('_');
    final messagesSnapshot = await FirebaseFirestore.instance
        .collection('chats')
        .doc(chatDocId)
        .collection('messages')
        .get();
    final batch = FirebaseFirestore.instance.batch();
    for (var doc in messagesSnapshot.docs) {
      batch.delete(doc.reference);
    }
    batch.delete(FirebaseFirestore.instance.collection('chats').doc(chatDocId));
    await batch.commit();
  }

  Future<void> _deleteEventInvitationsForFriend(String friendUid) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    // Delete invitations where the removed friend is the invited user
    final invitationsSnapshot = await FirebaseFirestore.instance
        .collection('eventInvitations')
        .where('invitedUserId', isEqualTo: friendUid)
        .where('creatorId', isEqualTo: currentUser.uid)
        .get();
    final batch = FirebaseFirestore.instance.batch();
    for (var doc in invitationsSnapshot.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();

    // Delete invitations where the friend invited you
    final friendInvitationsSnapshot = await FirebaseFirestore.instance
        .collection('eventInvitations')
        .where('invitedUserId', isEqualTo: currentUser.uid)
        .where('creatorId', isEqualTo: friendUid)
        .get();
    final batch2 = FirebaseFirestore.instance.batch();
    for (var doc in friendInvitationsSnapshot.docs) {
      batch2.delete(doc.reference);
    }
    await batch2.commit();

    // Remove the friend from any shared events
    final eventsSnapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser.uid)
        .collection('events')
        .where('sharedWith', arrayContains: friendUid)
        .get();
    final batch3 = FirebaseFirestore.instance.batch();
    for (var doc in eventsSnapshot.docs) {
      batch3.update(doc.reference, {
        'sharedWith': FieldValue.arrayRemove([friendUid])
      });
    }
    await batch3.commit();

    // Remove yourself from the friend's events' sharedWith array
    final friendEventsSnapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(friendUid)
        .collection('events')
        .where('sharedWith', arrayContains: currentUser.uid)
        .get();
    final batch4 = FirebaseFirestore.instance.batch();
    for (var doc in friendEventsSnapshot.docs) {
      batch4.update(doc.reference, {
        'sharedWith': FieldValue.arrayRemove([currentUser.uid])
      });
    }
    await batch4.commit();
  }

  Future<void> _startChat(String friendUid, String friendName) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      // First verify friendship
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .get();

      if (!userDoc.exists) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('You are not authorized to chat with this user')),
          );
        }
        return;
      }

      final friendUids = List<String>.from(userDoc.data()?['friendUids'] ?? []);
      if (!friendUids.contains(friendUid)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('You can only chat with your friends')),
          );
        }
        return;
      }

      // Create chat ID by sorting UIDs
      final chatId = [currentUser.uid, friendUid]..sort();
      final chatDocId = chatId.join('_');

      // Check if chat already exists
      final chatDoc = await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatDocId)
          .get();

      if (!chatDoc.exists) {
        // Create new chat document
        await FirebaseFirestore.instance.collection('chats').doc(chatDocId).set({
          'participants': [currentUser.uid, friendUid],
          'participantInfo': {
            currentUser.uid: {
              'displayName': currentUser.displayName ?? currentUser.email,
              'photoURL': currentUser.photoURL,
            },
            friendUid: {
              'displayName': friendName,
              'photoURL': null, // You might want to fetch this from the friend's user document
            },
          },
          'lastMessageTimestamp': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(
              friendId: friendUid,
              friendName: friendName,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error starting chat: $e')),
        );
      }
    }
  }

  void _viewFriendEvents(String uid, String displayName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FriendEventsScreen(friendUid: uid, friendName: displayName),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 24.0, bottom: 8.0),
      child: Row(
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          if (count > 0)
            Chip(
              label: Text(count.toString()),
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              labelStyle: TextStyle(
                color: Theme.of(context).colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.bold,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
              visualDensity: VisualDensity.compact,
            )
        ],
      ),
    );
  }

  Widget _buildAvatar(Map<String, dynamic> userData) {
    final String? photoURL = userData['photoURL'] as String?;
    final String displayName = userData['displayName']?.toString() ?? userData['email']?.toString() ?? "U";
    final String initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : "U";

    if (photoURL != null && photoURL.isNotEmpty) {
      return CircleAvatar(
        backgroundImage: NetworkImage(photoURL),
        radius: 20,
      );
    }
    return CircleAvatar(
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      radius: 20,
      child: Text(
        initial,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildEmptyState(String message, IconData icon) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40.0, horizontal: 16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 60,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createFriendGroup() async {
    final TextEditingController nameController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Friend Group'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            hintText: 'Enter group name',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;

      try {
        await FirebaseFirestore.instance.collection('friendGroups').add({
          'name': result,
          'createdBy': currentUser.uid,
          'members': [currentUser.uid],
          'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error creating group: $e')),
          );
        }
      }
    }
  }

  Future<void> _addToGroup(String friendId, String groupId) async {
    try {
      await FirebaseFirestore.instance.collection('friendGroups').doc(groupId).update({
        'members': FieldValue.arrayUnion([friendId]),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding friend to group: $e')),
        );
      }
    }
  }

  Future<void> _removeFromGroup(String friendId, String groupId) async {
    try {
      await FirebaseFirestore.instance.collection('friendGroups').doc(groupId).update({
        'members': FieldValue.arrayRemove([friendId]),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error removing friend from group: $e')),
        );
      }
    }
  }

  Widget _buildFriendGroups() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('friendGroups')
          .where('members', arrayContains: FirebaseAuth.instance.currentUser?.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final groups = snapshot.data!.docs;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Friend Groups',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: _createFriendGroup,
                    tooltip: 'Create new group',
                  ),
                ],
              ),
            ),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups[index].data() as Map<String, dynamic>;
                return ExpansionTile(
                  title: Text(group['name']),
                  children: [
                    StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('users')
                          .where('uid', whereIn: group['members'])
                          .snapshots(),
                      builder: (context, memberSnapshot) {
                        if (!memberSnapshot.hasData) {
                          return const Center(child: CircularProgressIndicator());
                        }

                        final members = memberSnapshot.data!.docs;
                        return Column(
                          children: members.map((member) {
                            final memberData = member.data() as Map<String, dynamic>;
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundImage: memberData['photoURL'] != null
                                    ? NetworkImage(memberData['photoURL'])
                                    : null,
                                child: memberData['photoURL'] == null
                                    ? Text(memberData['displayName'][0].toUpperCase())
                                    : null,
                              ),
                              title: Text(memberData['displayName']),
                              trailing: IconButton(
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () => _removeFromGroup(
                                  memberData['uid'],
                                  groups[index].id,
                                ),
                              ),
                            );
                          }).toList(),
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool showLoading = _isLoadingFriends || _isLoadingRequests;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Manage Friends',
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: showLoading && (_friends.isEmpty && _friendRequests.isEmpty)
            ? const Center(child: CircularProgressIndicator())
            : CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.all(16.0),
                    sliver: SliverToBoxAdapter(
                      child: TextFormField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: 'Search friends or add by email...',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _searchTerm.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.person_add_alt_1_outlined),
                                  tooltip: 'Add "${_searchTerm}" as friend',
                                  onPressed: () {
                                    if (_searchTerm.contains('@')) {
                                      _sendFriendRequest(_searchTerm.trim());
                                    } else {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Please enter a valid email to add a friend.'),
                                        ),
                                      );
                                    }
                                  },
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _buildSectionHeader(context, 'Friend Requests', _friendRequests.length),
                  ),
                  _isLoadingRequests && _friendRequests.isEmpty
                      ? const SliverToBoxAdapter(
                          child: Center(
                            child: Padding(
                              padding: EdgeInsets.all(16.0),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      : _friendRequests.isEmpty
                          ? SliverToBoxAdapter(
                              child: _buildEmptyState(
                                'No pending friend requests.',
                                Icons.person_add_disabled_outlined,
                              ),
                            )
                          : SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final req = _friendRequests[index];
                                  return Card(
                                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                    child: ListTile(
                                      leading: _buildAvatar(req),
                                      title: Text(
                                        req['displayName'] ?? req['email'] ?? 'Unknown User',
                                        style: GoogleFonts.inter(fontWeight: FontWeight.w500),
                                      ),
                                      subtitle: Text(
                                        req['email'] ?? 'No email',
                                        style: GoogleFonts.inter(fontSize: 12),
                                      ),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: Icon(
                                              Icons.check_circle_outline,
                                              color: theme.colorScheme.primary,
                                            ),
                                            tooltip: 'Accept',
                                            onPressed: () => _acceptFriendRequest(req['uid']),
                                          ),
                                          IconButton(
                                            icon: Icon(
                                              Icons.cancel_outlined,
                                              color: theme.colorScheme.error,
                                            ),
                                            tooltip: 'Reject',
                                            onPressed: () => _rejectFriendRequest(req['uid']),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                                childCount: _friendRequests.length,
                              ),
                            ),
                  SliverToBoxAdapter(
                    child: _buildSectionHeader(context, 'My Friends', _filteredFriends.length),
                  ),
                  _isLoadingFriends && _filteredFriends.isEmpty
                      ? const SliverToBoxAdapter(
                          child: Center(
                            child: Padding(
                              padding: EdgeInsets.all(16.0),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      : _filteredFriends.isEmpty
                          ? SliverToBoxAdapter(
                              child: _buildEmptyState(
                                _friends.isEmpty
                                    ? 'Add friends by searching their email above.'
                                    : 'No friends match your search.',
                                Icons.group_outlined,
                              ),
                            )
                          : SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final friend = _filteredFriends[index];
                                  return Card(
                                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                    child: ListTile(
                                      leading: _buildAvatar(friend),
                                      title: Text(
                                        friend['displayName'] ?? friend['email'] ?? 'Unknown User',
                                        style: GoogleFonts.inter(fontWeight: FontWeight.w500),
                                      ),
                                      subtitle: Text(
                                        friend['email'] ?? 'No email',
                                        style: GoogleFonts.inter(fontSize: 12),
                                      ),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: Icon(
                                              Icons.chat_outlined,
                                              color: theme.colorScheme.primary,
                                            ),
                                            onPressed: () => _startChat(
                                              friend['uid'],
                                              friend['displayName'] ?? friend['email'] ?? 'Friend',
                                            ),
                                            tooltip: 'Start chat',
                                          ),
                                          IconButton(
                                            icon: Icon(
                                              Icons.calendar_month_outlined,
                                              color: theme.colorScheme.secondary,
                                            ),
                                            onPressed: () => _viewFriendEvents(
                                              friend['uid'],
                                              friend['displayName'] ?? friend['email'] ?? 'Friend',
                                            ),
                                            tooltip: 'View public events',
                                          ),
                                          IconButton(
                                            icon: Icon(
                                              Icons.person_remove_outlined,
                                              color: theme.colorScheme.error.withOpacity(0.7),
                                            ),
                                            onPressed: () => _removeFriend(friend['uid']),
                                            tooltip: 'Remove friend',
                                          ),
                                        ],
                                      ),
                                      onTap: () => _viewFriendEvents(
                                        friend['uid'],
                                        friend['displayName'] ?? friend['email'] ?? 'Friend',
                                      ),
                                    ),
                                  );
                                },
                                childCount: _filteredFriends.length,
                              ),
                            ),
                  const SliverToBoxAdapter(child: SizedBox(height: 20)),
                ],
              ),
      ),
    );
  }
} 