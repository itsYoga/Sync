import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

// Provider to get the current user's chat with a specific friend
final chatProvider = StreamProvider.family<Map<String, dynamic>?, String>((ref, friendId) {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) return Stream.value(null);

  // Create a consistent chat ID by sorting the UIDs
  final chatId = [currentUser.uid, friendId]..sort();
  final chatDocId = chatId.join('_');

  return FirebaseFirestore.instance
      .collection('chats')
      .doc(chatDocId)
      .snapshots()
      .map((doc) => doc.data());
});

// Provider to get messages for a specific chat
final messagesProvider = StreamProvider.family<List<Map<String, dynamic>>, String>((ref, friendId) {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) return Stream.value([]);

  // Create a consistent chat ID by sorting the UIDs
  final chatId = [currentUser.uid, friendId]..sort();
  final chatDocId = chatId.join('_');

  return FirebaseFirestore.instance
      .collection('chats')
      .doc(chatDocId)
      .collection('messages')
      .orderBy('timestamp', descending: true)
      .snapshots()
      .map((snapshot) => snapshot.docs
          .map((doc) => {
                'id': doc.id,
                ...doc.data(),
              })
          .toList());
});

// Add these providers at the top with the other providers
final pinnedMessagesProvider = StreamProvider.family<List<Map<String, dynamic>>, String>((ref, friendId) {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) return Stream.value([]);

  final chatId = [currentUser.uid, friendId]..sort();
  final chatDocId = chatId.join('_');

  return FirebaseFirestore.instance
      .collection('chats')
      .doc(chatDocId)
      .collection('messages')
      .where('isPinned', isEqualTo: true)
      .orderBy('timestamp', descending: true)
      .snapshots()
      .map((snapshot) => snapshot.docs
          .map((doc) => {
                'id': doc.id,
                ...doc.data(),
              })
          .toList());
});

class ChatScreen extends ConsumerStatefulWidget {
  final String friendId;
  final String friendName;
  final String? friendPhotoUrl;

  const ChatScreen({
    super.key,
    required this.friendId,
    required this.friendName,
    this.friendPhotoUrl,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isComposing = false;
  bool _isFriend = false;

  @override
  void initState() {
    super.initState();
    _verifyFriendship();
  }

  Future<void> _verifyFriendship() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .get();

      if (!userDoc.exists) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('You are not authorized to chat with this user')),
          );
        }
        return;
      }

      final friendUids = List<String>.from(userDoc.data()?['friendUids'] ?? []);
      if (!friendUids.contains(widget.friendId)) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('You can only chat with your friends')),
          );
        }
        return;
      }

      if (mounted) {
        setState(() {
          _isFriend = true;
        });
        _markMessagesAsRead(); // Mark messages as read when chat is opened
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error verifying friendship: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _onRefresh() async {
    await Future.delayed(const Duration(milliseconds: 500));
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    // Prevent self-chatting
    if (currentUser.uid == widget.friendId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You cannot chat with yourself')),
      );
      return;
    }

    // Fetch sender display name and photo
    final userDoc = await FirebaseFirestore.instance.collection('users').doc(currentUser.uid).get();
    final String senderDisplayName = userDoc.data()?['displayName'] ?? currentUser.displayName ?? 'User';
    final String? senderPhoto = userDoc.data()?['photoURL'] ?? currentUser.photoURL;

    // Create a consistent chat ID by sorting the UIDs
    final chatId = [currentUser.uid, widget.friendId]..sort();
    final chatDocId = chatId.join('_');

    final message = {
      'senderId': currentUser.uid,
      'senderName': senderDisplayName,
      'senderPhotoURL': senderPhoto,
      'text': _messageController.text.trim(),
      'timestamp': FieldValue.serverTimestamp(),
      'isRetracted': false,
      'isPinned': false,
      'readBy': [currentUser.uid], // Sender has read the message
      'readAt': {
        currentUser.uid: FieldValue.serverTimestamp(),
      },
    };

    try {
      // Add message to the messages subcollection
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatDocId)
          .collection('messages')
          .add(message);

      // Update the chat document with last message info
      await FirebaseFirestore.instance.collection('chats').doc(chatDocId).set({
        'participants': chatId,
        'lastMessageText': message['text'],
        'lastMessageTimestamp': message['timestamp'],
        'lastMessageSenderId': message['senderId'],
        'participantInfo': {
          currentUser.uid: {
            'displayName': currentUser.displayName,
            'photoURL': currentUser.photoURL,
          },
          widget.friendId: {
            'displayName': widget.friendName,
            'photoURL': widget.friendPhotoUrl,
          },
        },
      }, SetOptions(merge: true));

      _messageController.clear();
      setState(() {
        _isComposing = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error sending message: $e')),
        );
      }
    }
  }

  Future<void> _retractMessage(String messageId) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final chatId = [currentUser.uid, widget.friendId]..sort();
    final chatDocId = chatId.join('_');

    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatDocId)
          .collection('messages')
          .doc(messageId)
          .update({
        'isRetracted': true,
        'text': 'This message was retracted',
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error retracting message: $e')),
        );
      }
    }
  }

  Future<void> _togglePinMessage(String messageId, bool isCurrentlyPinned) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final chatId = [currentUser.uid, widget.friendId]..sort();
    final chatDocId = chatId.join('_');

    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatDocId)
          .collection('messages')
          .doc(messageId)
          .update({
        'isPinned': !isCurrentlyPinned,
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error ${isCurrentlyPinned ? 'unpinning' : 'pinning'} message: $e')),
        );
      }
    }
  }

  Future<void> _markMessagesAsRead() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    if (!mounted) return;
    final chatId = [currentUser.uid, widget.friendId]..sort();
    final chatDocId = chatId.join('_');
    try {
      // Get messages sent by the friend
      final messagesSnapshot = await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatDocId)
          .collection('messages')
          .where('senderId', isEqualTo: widget.friendId)
          .get();
      final batch = FirebaseFirestore.instance.batch();
      int messagesMarkedAsRead = 0;
      for (var doc in messagesSnapshot.docs) {
        final messageData = doc.data();
        final List<dynamic> readByList = List.from(messageData['readBy'] as List<dynamic>? ?? []);
        if (!readByList.contains(currentUser.uid)) {
          batch.update(doc.reference, {
            'readBy': FieldValue.arrayUnion([currentUser.uid]),
            'readAt.${currentUser.uid}': FieldValue.serverTimestamp(),
          });
          messagesMarkedAsRead++;
        }
      }
      if (messagesMarkedAsRead > 0) {
        await batch.commit();
        print('Successfully marked $messagesMarkedAsRead message(s) as read.');
      }
    } catch (e) {
      print('Error marking messages as read: $e');
    }
  }

  void _showMessageOptions(BuildContext context, Map<String, dynamic> message) {
    final isMe = message['senderId'] == FirebaseAuth.instance.currentUser?.uid;
    final isRetracted = message['isRetracted'] as bool? ?? false;
    final isPinned = message['isPinned'] as bool? ?? false;

    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMe && !isRetracted)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Retract Message'),
                onTap: () {
                  Navigator.pop(context);
                  _retractMessage(message['id']);
                },
              ),
            ListTile(
              leading: Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(isPinned ? 'Unpin Message' : 'Pin Message'),
              onTap: () {
                Navigator.pop(context);
                _togglePinMessage(message['id'], isPinned);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showChatOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Clear Chat'),
              onTap: () async {
                Navigator.pop(context);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Clear Chat'),
                    content: const Text('Are you sure you want to clear all messages? This action cannot be undone.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Clear', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );

                if (confirm == true) {
                  final currentUser = FirebaseAuth.instance.currentUser;
                  if (currentUser == null) return;

                  final chatId = [currentUser.uid, widget.friendId]..sort();
                  final chatDocId = chatId.join('_');

                  try {
                    // Delete all messages
                    final messages = await FirebaseFirestore.instance
                        .collection('chats')
                        .doc(chatDocId)
                        .collection('messages')
                        .get();

                    final batch = FirebaseFirestore.instance.batch();
                    for (var doc in messages.docs) {
                      batch.delete(doc.reference);
                    }
                    await batch.commit();

                    // Update chat document
                    await FirebaseFirestore.instance
                        .collection('chats')
                        .doc(chatDocId)
                        .update({
                      'lastMessageText': null,
                      'lastMessageTimestamp': null,
                      'lastMessageSenderId': null,
                    });

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Chat cleared successfully')),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error clearing chat: $e')),
                      );
                    }
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.block, color: Colors.red),
              title: const Text('Block User'),
              onTap: () async {
                Navigator.pop(context);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Block User'),
                    content: Text('Are you sure you want to block ${widget.friendName}? You will no longer be able to send or receive messages from them.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Block', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );

                if (confirm == true) {
                  final currentUser = FirebaseAuth.instance.currentUser;
                  if (currentUser == null) return;

                  try {
                    // Add to blocked users list
                    await FirebaseFirestore.instance
                        .collection('users')
                        .doc(currentUser.uid)
                        .update({
                      'blockedUsers': FieldValue.arrayUnion([widget.friendId]),
                    });

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('User blocked successfully')),
                      );
                      Navigator.pop(context); // Return to previous screen
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error blocking user: $e')),
                      );
                    }
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editMessage(String messageId, String currentText) async {
    final TextEditingController editController = TextEditingController(text: currentText);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Message'),
        content: TextField(
          controller: editController,
          decoration: const InputDecoration(
            hintText: 'Edit your message',
          ),
          maxLines: null,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, editController.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result != currentText) {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;

      final chatId = [currentUser.uid, widget.friendId]..sort();
      final chatDocId = chatId.join('_');

      try {
        await FirebaseFirestore.instance
            .collection('chats')
            .doc(chatDocId)
            .collection('messages')
            .doc(messageId)
            .update({
          'text': result,
          'edited': true,
          'editedAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error editing message: $e')),
          );
        }
      }
    }
  }

  Future<void> _addReaction(String messageId, String reaction) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final chatId = [currentUser.uid, widget.friendId]..sort();
    final chatDocId = chatId.join('_');

    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatDocId)
          .collection('messages')
          .doc(messageId)
          .update({
        'reactions.${currentUser.uid}': reaction,
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding reaction: $e')),
        );
      }
    }
  }

  Future<void> _removeReaction(String messageId) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final chatId = [currentUser.uid, widget.friendId]..sort();
    final chatDocId = chatId.join('_');

    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatDocId)
          .collection('messages')
          .doc(messageId)
          .update({
        'reactions.${currentUser.uid}': FieldValue.delete(),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error removing reaction: $e')),
        );
      }
    }
  }

  Widget _buildMessageReactions(Map<String, dynamic> reactions) {
    if (reactions == null || reactions.isEmpty) return const SizedBox.shrink();

    // Group reactions by emoji
    final Map<String, List<String>> groupedReactions = {};
    reactions.forEach((userId, reaction) {
      if (!groupedReactions.containsKey(reaction)) {
        groupedReactions[reaction] = [];
      }
      groupedReactions[reaction]!.add(userId);
    });

    return Wrap(
      spacing: 4,
      children: groupedReactions.entries.map((entry) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceVariant,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(entry.key),
              const SizedBox(width: 2),
              Text(
                entry.value.length.toString(),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> message) {
    final data = message;
    final isMe = data['senderId'] == FirebaseAuth.instance.currentUser?.uid;
    final reactions = data['reactions'] as Map<String, dynamic>? ?? {};
    final senderName = data['senderName'] as String? ?? 'Unknown';
    final senderPhotoURL = data['senderPhotoURL'] as String?;
    final text = data['text'] as String? ?? '';
    final isEdited = data['edited'] as bool? ?? false;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isMe) ...[
                  CircleAvatar(
                    radius: 12,
                    backgroundImage: senderPhotoURL != null
                        ? NetworkImage(senderPhotoURL)
                        : null,
                    child: senderPhotoURL == null
                        ? Text(senderName[0].toUpperCase())
                        : null,
                  ),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: isMe
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceVariant,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!isMe)
                          Text(
                            senderName,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        Text(
                          text,
                          style: TextStyle(
                            color: isMe
                                ? Theme.of(context).colorScheme.onPrimary
                                : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (isEdited)
                          Text(
                            'edited',
                            style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 12,
                    backgroundImage: senderPhotoURL != null
                        ? NetworkImage(senderPhotoURL)
                        : null,
                    child: senderPhotoURL == null
                        ? Text(senderName[0].toUpperCase())
                        : null,
                  ),
                ],
              ],
            ),
            if (reactions.isNotEmpty) ...[
              const SizedBox(height: 4),
              _buildMessageReactions(reactions),
            ],
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isMe)
                  IconButton(
                    icon: const Icon(Icons.edit, size: 16),
                    onPressed: () => _editMessage(data['id'], text),
                    tooltip: 'Edit message',
                  ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.add_reaction_outlined, size: 16),
                  tooltip: 'Add reaction',
                  itemBuilder: (context) => [
                    '👍', '❤️', '😂', '😮', '😢', '👏'
                  ].map((emoji) => PopupMenuItem(
                    value: emoji,
                    child: Text(emoji),
                  )).toList(),
                  onSelected: (reaction) {
                    if (reactions[FirebaseAuth.instance.currentUser?.uid] == reaction) {
                      _removeReaction(data['id']);
                    } else {
                      _addReaction(data['id'], reaction);
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messagesAsyncValue = ref.watch(messagesProvider(widget.friendId));
    final pinnedMessagesAsyncValue = ref.watch(pinnedMessagesProvider(widget.friendId));
    final currentUser = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primaryContainer,
              backgroundImage: widget.friendPhotoUrl != null
                  ? NetworkImage(widget.friendPhotoUrl!)
                  : null,
              child: widget.friendPhotoUrl == null
                  ? Text(
                      widget.friendName.substring(0, 1).toUpperCase(),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Text(widget.friendName),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: _showChatOptions,
          ),
        ],
      ),
      body: Column(
        children: [
          // Show pinned messages if any
          pinnedMessagesAsyncValue.when(
            data: (pinnedMessages) {
              if (pinnedMessages.isEmpty) return const SizedBox.shrink();
              
              return Container(
                color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.push_pin, size: 16, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          'Pinned Messages',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 60,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: pinnedMessages.length,
                        itemBuilder: (context, index) {
                          final message = pinnedMessages[index];
                          return Container(
                            width: 200,
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: theme.colorScheme.outline.withOpacity(0.5),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  message['text'],
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                                const Spacer(),
                                Text(
                                  message['senderId'] == currentUser?.uid ? 'You' : widget.friendName,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _onRefresh,
              child: messagesAsyncValue.when(
                data: (messages) {
                  if (messages.isEmpty) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height - 200,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.chat_bubble_outline, size: 60, color: Colors.grey[400]),
                                const SizedBox(height: 16),
                                Text(
                                  'No messages yet',
                                  style: theme.textTheme.titleMedium?.copyWith(color: Colors.grey[600]),
                                ),
                                Text(
                                  'Start the conversation!',
                                  style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey[500]),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  }

                  return ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final isMe = message['senderId'] == currentUser?.uid;
                      final timestamp = message['timestamp'] as Timestamp?;
                      final timeString = timestamp != null
                          ? DateFormat.jm().format(timestamp.toDate())
                          : '';
                      final isRetracted = message['isRetracted'] as bool? ?? false;
                      final isPinned = message['isPinned'] as bool? ?? false;

                      return GestureDetector(
                        onLongPress: () => _showMessageOptions(context, message),
                        child: _buildMessageBubble(message),
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, stack) => Center(child: Text('Error: $err')),
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 4,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.attach_file),
                      onPressed: () {
                        // TODO: Implement file attachment
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('File attachment coming soon!')),
                        );
                      },
                    ),
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: theme.colorScheme.surfaceVariant,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                        ),
                        onChanged: (text) {
                          setState(() {
                            _isComposing = text.trim().isNotEmpty;
                          });
                        },
                        onSubmitted: (_) {
                          if (_isComposing) {
                            _sendMessage();
                          }
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send_rounded),
                      onPressed: _isComposing ? _sendMessage : null,
                      color: _isComposing
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface.withOpacity(0.38),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
} 