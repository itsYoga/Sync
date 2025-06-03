import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

const Color primaryAppColor = Colors.deepPurple;

class EventInvitation {
  final String id;
  final String eventId;
  final String creatorId;
  final String? eventCreatorDisplayName;
  final String invitedUserId;
  final String eventTitle;
  final DateTime eventDate;
  final String status;
  final DateTime createdAt;

  EventInvitation({
    required this.id,
    required this.eventId,
    required this.creatorId,
    this.eventCreatorDisplayName,
    required this.invitedUserId,
    required this.eventTitle,
    required this.eventDate,
    required this.status,
    required this.createdAt,
  });

  factory EventInvitation.fromFirestore(DocumentSnapshot doc) {
    Map data = doc.data() as Map<String, dynamic>;
    return EventInvitation(
      id: doc.id,
      eventId: data['eventId'] ?? '',
      creatorId: data['creatorId'] ?? '',
      eventCreatorDisplayName: data['creatorDisplayName'] ?? 'Unknown User',
      invitedUserId: data['invitedUserId'] ?? '',
      eventTitle: data['eventTitle'] ?? 'Untitled Event',
      eventDate: (data['eventDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      status: data['status'] ?? 'pending',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}

class EventInvitationsScreen extends StatefulWidget {
  const EventInvitationsScreen({super.key});

  @override
  State<EventInvitationsScreen> createState() => _EventInvitationsScreenState();
}

class _EventInvitationsScreenState extends State<EventInvitationsScreen> {
  final User? _currentUser = FirebaseAuth.instance.currentUser;
  late ScaffoldMessengerState _scaffoldMessenger;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scaffoldMessenger = ScaffoldMessenger.of(context);
  }

  Stream<List<EventInvitation>> _getInvitationsStream() {
    if (_currentUser == null) {
      return Stream.value([]);
    }
    return FirebaseFirestore.instance
        .collection('eventInvitations')
        .where('invitedUserId', isEqualTo: _currentUser!.uid)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => EventInvitation.fromFirestore(doc))
            .toList());
  }

  Future<void> _updateInvitationStatus(String invitationId, String newStatus) async {
    try {
      await FirebaseFirestore.instance
          .collection('eventInvitations')
          .doc(invitationId)
          .update({
            'status': newStatus,
            'lastModified': FieldValue.serverTimestamp(),
          });
          
      if (mounted) {
        _scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('Invitation ${newStatus == "accepted" ? "accepted" : "declined"}')),
        );
      }
    } catch (e) {
      if (mounted) {
        _scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('Failed to update invitation: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Event Invitations', style: GoogleFonts.lato(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 1,
      ),
      body: StreamBuilder<List<EventInvitation>>(
        stream: _getInvitationsStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: SelectableText('Error: \\${snapshot.error}'));
          }
          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return Center(
              child: Text(
                'No pending invitations.',
                style: GoogleFonts.lato(fontSize: 16, color: Colors.grey),
              ),
            );
          }

          final invitations = snapshot.data!;

          return ListView.builder(
            padding: const EdgeInsets.all(8.0),
            itemCount: invitations.length,
            itemBuilder: (context, index) {
              final invite = invitations[index];
              return Card(
                elevation: 2,
                margin: const EdgeInsets.symmetric(vertical: 8.0),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        invite.eventTitle,
                        style: GoogleFonts.lato(fontSize: 18, fontWeight: FontWeight.bold, color: primaryAppColor),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Date: ${DateFormat('MMM dd, yyyy hh:mm a').format(invite.eventDate)}',
                        style: GoogleFonts.lato(fontSize: 14, color: Colors.grey[700]),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Invited by: ${invite.eventCreatorDisplayName}',
                        style: GoogleFonts.lato(fontSize: 14, color: Colors.grey[700]),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => _updateInvitationStatus(invite.id, 'declined'),
                            child: Text('Decline', style: GoogleFonts.lato(color: Colors.redAccent)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () => _updateInvitationStatus(invite.id, 'accepted'),
                            style: ElevatedButton.styleFrom(backgroundColor: primaryAppColor),
                            child: Text('Accept', style: GoogleFonts.lato(color: Colors.white)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
} 