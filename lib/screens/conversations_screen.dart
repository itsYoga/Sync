import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'chat_with_gemini.dart'; // Your existing Gemini chat screen
import 'chat_screen.dart'; // Add this import

final chatListProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) {
    return Stream.value([]);
  }

  return FirebaseFirestore.instance
      .collection('users')
      .doc(currentUser.uid)
      .snapshots()
      .asyncMap((userDoc) async {
        if (!userDoc.exists) return [];
        
        final friendUids = List<String>.from(userDoc.data()?['friendUids'] ?? []);
        if (friendUids.isEmpty) return [];

        final chatsSnapshot = await FirebaseFirestore.instance
            .collection('chats')
            .where('participants', arrayContains: currentUser.uid)
            .orderBy('lastMessageTimestamp', descending: true)
            .get();

        List<Map<String, dynamic>> detailedChats = [];
        for (final chatDoc in chatsSnapshot.docs) {
          final chatData = chatDoc.data();
          final participants = List<String>.from(chatData['participants'] ?? []);
          if (participants.length != 2) continue;
          
          final String friendId = participants.firstWhere((id) => id != currentUser.uid);
          if (!friendUids.contains(friendId)) continue; // Only include chats with friends

          final participantInfo = chatData['participantInfo'] as Map<String, dynamic>? ?? {};
          final friendInfoMap = participantInfo[friendId] as Map<String, dynamic>?;
          if (friendInfoMap == null) continue;

          int unreadCount = 0;
          try {
            final unreadMessagesSnapshot = await FirebaseFirestore.instance
                .collection('chats')
                .doc(chatDoc.id)
                .collection('messages')
                .where('senderId', isEqualTo: friendId)
                .get();
            for (final messageDoc in unreadMessagesSnapshot.docs) {
              final messageData = messageDoc.data();
              final readByList = List<String>.from(messageData['readBy'] ?? []);
              if (!readByList.contains(currentUser.uid)) {
                unreadCount++;
              }
            }
          } catch (e) {}

          detailedChats.add({
            'chatId': chatDoc.id,
            'friendId': friendId,
            'friendDisplayName': friendInfoMap['displayName'] ?? 'Unknown User',
            'friendPhotoURL': friendInfoMap['photoURL'] as String?,
            'lastMessageText': chatData['lastMessageText'] as String? ?? '',
            'lastMessageTimestamp': chatData['lastMessageTimestamp'] as Timestamp?,
            'lastMessageSenderId': chatData['lastMessageSenderId'] as String?,
            'unreadCount': unreadCount,
          });
        }
        return detailedChats;
      });
});

class ConversationsScreen extends ConsumerWidget {
  const ConversationsScreen({super.key});

  Future<void> _onRefresh(WidgetRef ref) async {
    ref.invalidate(chatListProvider);
    await Future.delayed(const Duration(milliseconds: 500));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final chatListAsyncValue = ref.watch(chatListProvider);
    final currentUser = FirebaseAuth.instance.currentUser;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          toolbarHeight: 0,
          bottom: TabBar(
            labelStyle: GoogleFonts.lato(fontWeight: FontWeight.bold),
            unselectedLabelStyle: GoogleFonts.lato(),
            indicatorColor: theme.colorScheme.primary,
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: theme.colorScheme.onSurface.withOpacity(0.7),
            tabs: const [
              Tab(text: 'CHATS WITH FRIENDS'),
              Tab(text: 'AI ASSISTANT'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            RefreshIndicator(
              onRefresh: () => _onRefresh(ref),
              child: chatListAsyncValue.when(
                data: (chats) {
                  if (chats.isEmpty) {
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
                                  'No conversations yet.',
                                  style: theme.textTheme.titleMedium?.copyWith(color: Colors.grey[600]),
                                ),
                                Text(
                                  'Start a chat with your friends!',
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
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: chats.length,
                    itemBuilder: (context, index) {
                      final chat = chats[index];
                      final photoUrl = chat['friendPhotoURL'] as String?;
                      final friendName = chat['friendDisplayName'] as String? ?? 'Unknown';
                      final lastMessageText = chat['lastMessageText'] as String? ?? "";
                      final lastMessageSenderId = chat['lastMessageSenderId'] as String?;
                      final lastMessageTimestamp = chat['lastMessageTimestamp'] as Timestamp?;
                      final unreadCount = chat['unreadCount'] as int? ?? 0;

                      String subtitleDisplay = "No messages yet";
                      if (lastMessageText.isNotEmpty) {
                        if (lastMessageSenderId == currentUser?.uid) {
                          subtitleDisplay = "You: $lastMessageText";
                        } else {
                          subtitleDisplay = lastMessageText;
                        }
                      }

                      return ListTile(
                        leading: CircleAvatar(
                          radius: 25,
                          backgroundColor: theme.colorScheme.primaryContainer,
                          backgroundImage: (photoUrl != null && photoUrl.isNotEmpty)
                              ? NetworkImage(photoUrl)
                              : null,
                          child: (photoUrl == null || photoUrl.isEmpty)
                              ? Text(
                                  friendName.substring(0, 1).toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.onPrimaryContainer,
                                  ),
                                )
                              : null,
                        ),
                        title: Text(
                          friendName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: unreadCount > 0 ? theme.colorScheme.primary : null,
                          ),
                        ),
                        subtitle: Text(
                          subtitleDisplay,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: unreadCount > 0 ? theme.colorScheme.onSurface : Colors.grey[600],
                            fontWeight: unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (lastMessageTimestamp != null)
                              Text(
                                DateFormat.jm().format(lastMessageTimestamp.toDate()),
                                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                              ),
                            if (unreadCount > 0) ...[
                              const SizedBox(height: 4),
                              CircleAvatar(
                                radius: 10,
                                backgroundColor: theme.colorScheme.error,
                                child: Text(
                                  '$unreadCount',
                                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ]
                          ],
                        ),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ChatScreen(
                                friendId: chat['friendId'],
                                friendName: friendName,
                                friendPhotoUrl: photoUrl,
                              ),
                            ),
                          );
                          ref.invalidate(chatListProvider);
                        },
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, stack) {
                  print('Error loading chats: ' + err.toString());
                  print(stack);
                  return Center(child: Text('Error loading chats: $err\n$stack'));
                },
              ),
            ),
            // --- Tab 2: AI Assistant ---
            const ChatWithGeminiScreen(),
          ],
        ),
      ),
    );
  }
} 