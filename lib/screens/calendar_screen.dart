import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'; // Keep if you use Riverpod elsewhere, not directly used in this snippet for simplicity
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../widgets/event_edit_dialog.dart';
import '../widgets/event_invitations_screen.dart';
import '../main.dart'; // Import for pendingInvitationsProvider
import '../widgets/add_event_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

const Color primaryAppColor = Colors.deepPurple;
const Color accentAppColor = Colors.pinkAccent;
const Color surfaceAppColor = Colors.white;
const Color cardAppColor = Color(0xFFF8F8F8);

enum EventCategory {
  personal,
  work,
  social,
  family,
  health,
  other;

  String get displayName {
    switch (this) {
      case EventCategory.personal:
        return 'Personal';
      case EventCategory.work:
        return 'Work';
      case EventCategory.social:
        return 'Social';
      case EventCategory.family:
        return 'Family';
      case EventCategory.health:
        return 'Health';
      case EventCategory.other:
        return 'Other';
    }
  }

  Color get color {
    switch (this) {
      case EventCategory.personal:
        return Colors.blue;
      case EventCategory.work:
        return Colors.orange;
      case EventCategory.social:
        return Colors.purple;
      case EventCategory.family:
        return Colors.green;
      case EventCategory.health:
        return Colors.red;
      case EventCategory.other:
        return Colors.grey;
    }
  }

  IconData get icon {
    switch (this) {
      case EventCategory.personal:
        return Icons.person;
      case EventCategory.work:
        return Icons.work;
      case EventCategory.social:
        return Icons.people;
      case EventCategory.family:
        return Icons.family_restroom;
      case EventCategory.health:
        return Icons.favorite;
      case EventCategory.other:
        return Icons.category;
    }
  }
}

class CalendarScreen extends ConsumerStatefulWidget {
  final DateTime? initialDate;
  const CalendarScreen({super.key, this.initialDate});

  static void updateDate(DateTime date) {
    _CalendarScreenState? state = _currentState;
    if (state != null && state.mounted) {
      state.setState(() {
        state._focusedDay = date;
        state._selectedDay = date;
      });
    }
  }

  static _CalendarScreenState? _currentState;

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  CalendarFormat _calendarFormat = CalendarFormat.month;
  late DateTime _focusedDay;
  DateTime? _selectedDay;
  Map<DateTime, List<Event>> _events = {};

  @override
  void initState() {
    super.initState();
    _focusedDay = widget.initialDate ?? DateTime.now();
    _selectedDay = _focusedDay;
    _loadEvents();
    CalendarScreen._currentState = this;
  }

  @override
  void dispose() {
    if (CalendarScreen._currentState == this) {
      CalendarScreen._currentState = null;
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(CalendarScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialDate != oldWidget.initialDate) {
      setState(() {
        _focusedDay = widget.initialDate ?? DateTime.now();
        _selectedDay = _focusedDay;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.initialDate != null) {
      setState(() {
        _focusedDay = widget.initialDate!;
        _selectedDay = _focusedDay;
      });
    }
  }

  Future<void> _loadEvents() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _events = {});
      return;
    }
    final localEvents = <DateTime, List<Event>>{};
    
    // 1. Load events created by the user
    final ownedEventsSnapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('events')
        .orderBy('date', descending: false)
        .get();
    for (var doc in ownedEventsSnapshot.docs) {
      final data = doc.data();
      final date = (data['date'] as Timestamp).toDate();
      final endDate = data['endDate'] != null ? (data['endDate'] as Timestamp).toDate() : null;
      Map<String, dynamic>? locationData;
      if (data['location'] != null) {
        if (data['location'] is Map) {
          locationData = Map<String, dynamic>.from(data['location'] as Map);
        } else if (data['location'] is String) {
          locationData = {
            'address': data['location'],
            'lat': null,
            'lng': null,
          };
        } else {
          locationData = null;
        }
      }
      final event = Event(
        id: doc.id,
        title: data['title'],
        description: data['description'] ?? '',
        location: locationData,
        isPrivate: data['isPrivate'] ?? false,
        sharedWith: List<String>.from(data['sharedWith'] ?? []),
        date: date,
        endDate: endDate,
        creatorId: data['creatorId'] ?? user.uid,
        creatorDisplayName: data['creatorDisplayName'] ?? user.displayName ?? user.email ?? 'A user',
        category: EventCategory.values.firstWhere(
          (e) => e.name == (data['category'] as String? ?? 'other'),
          orElse: () => EventCategory.other,
        ),
      );
      addEventToMap(event, localEvents);
    }

    // 2. Load events the user has accepted invitations to
    final acceptedInvitationsSnapshot = await FirebaseFirestore.instance
        .collection('eventInvitations')
        .where('invitedUserId', isEqualTo: user.uid)
        .where('status', isEqualTo: 'accepted')
        .get();

    for (var inviteDoc in acceptedInvitationsSnapshot.docs) {
      final inviteData = inviteDoc.data();
      final String eventId = inviteData['eventId'];
      final String creatorId = inviteData['creatorId'];
      
      try {
        final eventDocSnapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(creatorId)
            .collection('events')
            .doc(eventId)
            .get();
            
        if (eventDocSnapshot.exists) {
          final eventData = eventDocSnapshot.data()!;
          final date = (eventData['date'] as Timestamp).toDate();
          final endDate = eventData['endDate'] != null ? (eventData['endDate'] as Timestamp).toDate() : null;
          Map<String, dynamic>? locationDataShared;
          if (eventData['location'] != null) {
            if (eventData['location'] is Map) {
              locationDataShared = Map<String, dynamic>.from(eventData['location'] as Map);
            } else if (eventData['location'] is String) {
              locationDataShared = {
                'address': eventData['location'],
                'lat': null,
                'lng': null,
              };
            } else {
              locationDataShared = null;
            }
          }
          final event = Event(
            id: eventDocSnapshot.id,
            title: eventData['title'],
            description: eventData['description'] ?? '',
            location: locationDataShared,
            isPrivate: eventData['isPrivate'] ?? false,
            sharedWith: List<String>.from(eventData['sharedWith'] ?? []),
            date: date,
            endDate: endDate,
            creatorId: eventData['creatorId'] ?? creatorId,
            creatorDisplayName: inviteData['creatorDisplayName'] ?? eventData['creatorDisplayName'] ?? 'Unknown',
            category: EventCategory.values.firstWhere(
              (e) => e.name == (eventData['category'] as String? ?? 'other'),
              orElse: () => EventCategory.other,
            ),
          );
          addEventToMap(event, localEvents);
        }
      } catch (e) {
        if (mounted) {
          print("Error fetching shared event $eventId from $creatorId: $e");
        }
      }
    }

    if (mounted) {
      setState(() {
        _events = localEvents;
      });
    }
  }

  void addEventToMap(Event event, Map<DateTime, List<Event>> localEvents) {
    DateTime dayCursor = DateTime.utc(event.date.year, event.date.month, event.date.day);
    DateTime finalDay = event.endDate != null
        ? DateTime.utc(event.endDate!.year, event.endDate!.month, event.endDate!.day)
        : dayCursor;
    while (!dayCursor.isAfter(finalDay)) {
      if (localEvents[dayCursor] == null) localEvents[dayCursor] = [];
      if (!localEvents[dayCursor]!.any((e) => e.id == event.id && e.creatorId == event.creatorId)) {
        localEvents[dayCursor]!.add(event);
      }
      dayCursor = dayCursor.add(const Duration(days: 1));
    }
  }

  List<Event> _getEventsForDay(DateTime day) {
    final key = DateTime.utc(day.year, day.month, day.day);
    final events = _events[key] ?? [];
    return events;
  }

  Future<void> _addOrEditEvent({Event? existingEvent}) async {
    List<Map<String, dynamic>> friendsList = [];
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You need to be logged in to manage events.'))
      );
      return;
    }
    // Fetch friends list
    try {
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final List<dynamic> friendUidsFromDb = userDoc.data()?['friendUids'] as List<dynamic>? ?? 
                                           userDoc.data()?['friends'] as List<dynamic>? ?? [];
      for (String uid in friendUidsFromDb.cast<String>()) {
        final friendDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
        if (friendDoc.exists) {
          friendsList.add({
            'uid': uid,
            'displayName': friendDoc.data()?['displayName'] ?? friendDoc.data()?['email'] ?? 'Unnamed Friend',
            'email': friendDoc.data()?['email'] ?? 'No email',
          });
        }
      }
    } catch (e) {
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching friends: $e.'))
        );
      }
    }

    await showDialog(
      context: context,
      builder: (context) => EventEditDialog(
        initialTitle: existingEvent?.title,
        initialDescription: existingEvent?.description,
        initialLocation: existingEvent?.address,
        initialDate: existingEvent?.date ?? _selectedDay ?? DateTime.now(),
        initialEndDate: existingEvent?.endDate,
        initialIsPrivate: existingEvent?.isPrivate ?? false,
        friendsList: friendsList,
        initialSelectedFriendUids: existingEvent?.sharedWith ?? [],
        onSave: (title, description, locationMap, date, endDate, isPrivate, selectedFriendUids, category) async {
          final currentUser = FirebaseAuth.instance.currentUser;
          if (currentUser == null) return;
          final eventData = {
            'title': title,
            'description': description,
            'location': locationMap,
            'date': Timestamp.fromDate(date),
            'endDate': endDate != null ? Timestamp.fromDate(endDate) : null,
            'isPrivate': isPrivate,
            'sharedWith': isPrivate ? [] : selectedFriendUids,
            'lastModified': FieldValue.serverTimestamp(),
            'creatorId': currentUser.uid,
            'creatorDisplayName': currentUser.displayName ?? currentUser.email ?? 'A user',
            'category': category.name,
          };
          String? eventId = existingEvent?.id;
          try {
            if (existingEvent != null) {
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(currentUser.uid)
                  .collection('events')
                  .doc(existingEvent.id)
                  .update(eventData);
            } else {
              final newEventRef = await FirebaseFirestore.instance
                  .collection('users')
                  .doc(currentUser.uid)
                  .collection('events')
                  .add(eventData);
              eventId = newEventRef.id;
            }
            // Create invitations if event is not private and there are selected friends
            if (!isPrivate && selectedFriendUids.isNotEmpty && eventId != null) {
              final creatorDisplayName = currentUser.displayName ?? currentUser.email ?? 'A user';
              for (String friendUid in selectedFriendUids) {
                if (friendUid == currentUser.uid) continue; // Don't invite self
                
                try {
                  // Check if a pending invitation already exists to avoid duplicates
                  final existingPendingInviteQuery = await FirebaseFirestore.instance
                      .collection('eventInvitations')
                      .where('eventId', isEqualTo: eventId)
                      .where('invitedUserId', isEqualTo: friendUid)
                      .where('status', whereIn: ['pending', 'accepted'])
                      .limit(1)
                      .get();
                      
                  if (existingPendingInviteQuery.docs.isEmpty) {
                    await FirebaseFirestore.instance.collection('eventInvitations').add({
                      'eventId': eventId,
                      'creatorId': currentUser.uid,
                      'creatorDisplayName': creatorDisplayName,
                      'invitedUserId': friendUid,
                      'eventTitle': title,
                      'eventDate': Timestamp.fromDate(date),
                      'status': 'pending',
                      'createdAt': FieldValue.serverTimestamp(),
                      'lastModified': FieldValue.serverTimestamp(),
                    });
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to send invitation: $e')),
                    );
                  }
                }
              }
            }
            if (Navigator.canPop(context)) Navigator.pop(context); // Close dialog
            if (mounted) {
              _loadEvents(); // Refresh calendar
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Event saved successfully')),
              );
            }
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to save event: $e')),
            );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context); // Get theme for colors
    return Scaffold(
      backgroundColor: theme.colorScheme.background,
      appBar: AppBar(
        title: null,
        backgroundColor: surfaceAppColor,
        elevation: 1,
        actions: [
          Consumer(
            builder: (context, ref, child) {
              final pendingCountAsyncValue = ref.watch(pendingInvitationsProvider);

              return pendingCountAsyncValue.when(
                data: (count) {
                  return Badge(
                    label: Text(
                      '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    isLabelVisible: count > 0,
                    backgroundColor: Colors.red,
                    offset: const Offset(4, -4),
                    child: IconButton(
                      icon: Icon(Icons.mail_outline, color: primaryAppColor, size: 26),
                      tooltip: 'View Invitations (${count > 0 ? '$count pending' : 'No pending'})',
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => const EventInvitationsScreen()),
                        );
                      },
                    ),
                  );
                },
                loading: () {
                  return IconButton(
                    icon: Icon(Icons.mail_outline, color: primaryAppColor, size: 26),
                    tooltip: 'View Invitations',
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const EventInvitationsScreen()),
                      );
                    },
                  );
                },
                error: (error, stackTrace) {
                  return IconButton(
                    icon: Icon(Icons.mail_outline, color: Colors.grey, size: 26),
                    tooltip: 'Error loading invitations',
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Could not load invitation count: $error'))
                      );
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const EventInvitationsScreen()),
                      );
                    },
                  );
                },
              );
            },
          ),
          IconButton(
            icon: Icon(Icons.add_circle_outline, color: primaryAppColor, size: 28),
            onPressed: () => _showNewEventDialog(),
          ),
          IconButton(
            icon: Icon(Icons.refresh, color: primaryAppColor),
            onPressed: _loadEvents,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
             margin: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: surfaceAppColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: TableCalendar<Event>(
              firstDay: DateTime.utc(2020, 1, 1),
              lastDay: DateTime.utc(2030, 12, 31),
              focusedDay: _focusedDay,
              calendarFormat: _calendarFormat,
              selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
              onDaySelected: (selectedDay, focusedDay) {
                final utcSelected = DateTime.utc(selectedDay.year, selectedDay.month, selectedDay.day);
                final utcFocused = DateTime.utc(focusedDay.year, focusedDay.month, focusedDay.day);
                if (!isSameDay(_selectedDay, utcSelected)) {
                  setState(() {
                    _selectedDay = utcSelected;
                    _focusedDay = utcFocused;
                  });
                }
              },
              onFormatChanged: (format) {
                if (_calendarFormat != format) {
                  setState(() { _calendarFormat = format; });
                }
              },
              onPageChanged: (focusedDay) {
                _focusedDay = focusedDay;
              },
              eventLoader: _getEventsForDay,
              calendarStyle: CalendarStyle(
                todayDecoration: BoxDecoration(
                  color: accentAppColor.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                selectedDecoration: BoxDecoration(
                  color: primaryAppColor,
                  shape: BoxShape.circle,
                ),
                markerDecoration: BoxDecoration(
                  color: accentAppColor,
                  shape: BoxShape.circle,
                ),
                markersMaxCount: 3,
                outsideDaysVisible: false,
                defaultTextStyle: GoogleFonts.lato(),
                weekendTextStyle: GoogleFonts.lato(color: Colors.red[600]),
              ),
              headerStyle: HeaderStyle(
                titleTextStyle: GoogleFonts.lato(fontSize: 18, fontWeight: FontWeight.bold),
                formatButtonTextStyle: GoogleFonts.lato(),
                formatButtonDecoration: BoxDecoration(
                  border: Border.all(color: Colors.grey[400]!),
                  borderRadius: BorderRadius.circular(12),
                ),
                leftChevronIcon: const Icon(Icons.chevron_left, color: primaryAppColor),
                rightChevronIcon: const Icon(Icons.chevron_right, color: primaryAppColor),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                Text(
                  _selectedDay != null ? DateFormat('EEEE, MMM dd').format(_selectedDay!) : 'No day selected',
                  style: GoogleFonts.lato(fontSize: 18, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface),
                ),
                const Spacer(),
                if (_selectedDay != null && _getEventsForDay(_selectedDay!).isNotEmpty)
                   Chip(
                    label: Text('${_getEventsForDay(_selectedDay!).length} events', style: GoogleFonts.lato(color: Colors.white)),
                    backgroundColor: accentAppColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  )
              ],
            ),
          ),
          Expanded(
            child: _selectedDay == null
                ? Center(child: Text('Select a day to view events', style: GoogleFonts.lato(fontSize: 16, color: Colors.grey)))
                : _getEventsForDay(_selectedDay!).isEmpty
                  ? Center(child: Text('No events for this day 🎉', style: GoogleFonts.lato(fontSize: 16, color: Colors.grey)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      itemCount: _getEventsForDay(_selectedDay!).length,
                      itemBuilder: (context, index) {
                        final event = _getEventsForDay(_selectedDay!)[index];
                        final bool isOwnedByCurrentUser = event.creatorId == FirebaseAuth.instance.currentUser?.uid;
                        return Card(
                          elevation: 2,
                          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          color: cardAppColor,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            leading: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  event.category.icon,
                                  color: event.category.color,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  event.isPrivate ? Icons.lock_outline : Icons.event_available_outlined,
                                  color: event.isPrivate ? Colors.orangeAccent : primaryAppColor,
                                ),
                              ],
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    event.title,
                                    style: GoogleFonts.lato(fontWeight: FontWeight.w600),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: event.category.color.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: event.category.color.withOpacity(0.3)),
                                  ),
                                  child: Text(
                                    event.category.displayName,
                                    style: GoogleFonts.lato(
                                      fontSize: 12,
                                      color: event.category.color,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            subtitle: event.description.isNotEmpty
                                ? Text(event.description, style: GoogleFonts.lato(), maxLines: 2, overflow: TextOverflow.ellipsis)
                                : null,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isOwnedByCurrentUser)
                                  IconButton(
                                    icon: Icon(Icons.edit_outlined, size: 20, color: Colors.grey[600]),
                                    onPressed: () => _addOrEditEvent(existingEvent: event),
                                  ),
                                if (isOwnedByCurrentUser)
                                  IconButton(
                                    icon: Icon(Icons.delete_outline, size: 20, color: Colors.red[400]),
                                    tooltip: 'Delete event',
                                    onPressed: () async {
                                      final confirm = await showDialog<bool>(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: const Text('Delete Event'),
                                          content: const Text('Are you sure you want to delete this event?'),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.of(ctx).pop(false),
                                              child: const Text('Cancel'),
                                            ),
                                            TextButton(
                                              onPressed: () => Navigator.of(ctx).pop(true),
                                              child: const Text('Delete', style: TextStyle(color: Colors.red)),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (confirm == true) {
                                        final user = FirebaseAuth.instance.currentUser;
                                        if (user != null) {
                                          await FirebaseFirestore.instance
                                            .collection('users')
                                            .doc(user.uid)
                                            .collection('events')
                                            .doc(event.id)
                                            .delete();
                                          if (mounted) _loadEvents();
                                        }
                                      }
                                    },
                                  ),
                              ],
                            ),
                            onTap: () {
                               showDialog(context: context, builder: (ctx) => AlertDialog(
                                title: Text(event.title, style: GoogleFonts.lato(color: primaryAppColor, fontWeight: FontWeight.bold)),
                                content: SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(event.category.icon, color: event.category.color),
                                          const SizedBox(width: 8),
                                          Text(
                                            event.category.displayName,
                                            style: GoogleFonts.lato(
                                              color: event.category.color,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text("Date: ${DateFormat('MMM dd, yyyy').format(event.date)}", style: GoogleFonts.lato()),
                                      const SizedBox(height: 8),
                                      Text("Description:", style: GoogleFonts.lato(fontWeight: FontWeight.bold)),
                                      Text(event.description.isNotEmpty ? event.description : "No description.", style: GoogleFonts.lato()),
                                      const SizedBox(height: 8),
                                      Text("Privacy: ${event.isPrivate ? "Private" : "Public (shared with ${event.sharedWith.length} friends)"}", style: GoogleFonts.lato()),
                                      if (!isOwnedByCurrentUser) ...[
                                        const SizedBox(height: 8),
                                        Text("Created by: ${event.creatorDisplayName ?? 'Unknown'}", style: GoogleFonts.lato()),
                                      ],
                                      if (event.sharedWith.isNotEmpty && !event.isPrivate) ...[
                                        const SizedBox(height: 8),
                                        // You could fetch and display friend names here if needed
                                        // For now, just showing the count.
                                      ],
                                      if (event.location != null) ...[
                                        const SizedBox(height: 8),
                                        Text("Location:", style: GoogleFonts.lato(fontWeight: FontWeight.bold)),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                event.location!['address'] ?? 'No address',
                                                style: GoogleFonts.lato(),
                                              ),
                                            ),
                                            if (event.lat != null && event.lng != null)
                                              IconButton(
                                                icon: const Icon(Icons.navigation, color: Colors.blue),
                                                onPressed: () async {
                                                  final url = 'https://www.google.com/maps/dir/?api=1&destination=${event.lat},${event.lng}';
                                                  if (await canLaunchUrl(Uri.parse(url))) {
                                                    await launchUrl(Uri.parse(url));
                                                  } else {
                                                    if (mounted) {
                                                      ScaffoldMessenger.of(context).showSnackBar(
                                                        const SnackBar(content: Text('Could not launch navigation')),
                                                      );
                                                    }
                                                  }
                                                },
                                                tooltip: 'Navigate to this location',
                                              ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                actions: [
                                  if (!isOwnedByCurrentUser)
                                    TextButton.icon(
                                      icon: const Icon(Icons.edit_calendar),
                                      label: const Text('Request Change'),
                                      onPressed: () async {
                                        Navigator.pop(ctx); // Close the event details dialog
                                        final TextEditingController reasonController = TextEditingController();
                                        final reason = await showDialog<String>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: const Text('Request Change'),
                                            content: TextField(
                                              controller: reasonController,
                                              decoration: const InputDecoration(
                                                labelText: 'Reason for change',
                                                hintText: 'Enter your reason for requesting a change...',
                                              ),
                                              maxLines: 3,
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(context),
                                                child: const Text('Cancel'),
                                              ),
                                              TextButton(
                                                onPressed: () => Navigator.pop(context, reasonController.text),
                                                child: const Text('Submit'),
                                              ),
                                            ],
                                          ),
                                        );

                                        if (reason != null && reason.isNotEmpty) {
                                          try {
                                            // Find the invitation document for this event
                                            final invitationQuery = await FirebaseFirestore.instance
                                                .collection('eventInvitations')
                                                .where('eventId', isEqualTo: event.id)
                                                .where('invitedUserId', isEqualTo: FirebaseAuth.instance.currentUser?.uid)
                                                .where('status', isEqualTo: 'accepted')
                                                .limit(1)
                                                .get();

                                            if (invitationQuery.docs.isNotEmpty) {
                                              final invitationDoc = invitationQuery.docs.first;
                                              await invitationDoc.reference.update({
                                                'status': 'change_requested',
                                                'changeRequestReason': reason,
                                                'changeRequestedAt': FieldValue.serverTimestamp(),
                                              });

                                              if (mounted) {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  const SnackBar(content: Text('Change request sent to event creator')),
                                                );
                                              }
                                            } else {
                                              if (mounted) {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  const SnackBar(content: Text('Could not find the event invitation')),
                                                );
                                              }
                                            }
                                          } catch (e) {
                                            if (mounted) {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(content: Text('Error sending request: $e')),
                                              );
                                            }
                                          }
                                        }
                                      },
                                    ),
                                  TextButton(
                                    onPressed: () => Navigator.of(ctx).pop(),
                                    child: Text("Close", style: GoogleFonts.lato())
                                  ),
                                ],
                              ));
                            },
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }

  Future<void> _showNewEventDialog() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AddEventDialog(
        initialDate: _selectedDay ?? DateTime.now(),
        friendsList: ref.watch(friendsListProvider).value ?? [],
      ),
    );

    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Event created successfully!')),
      );
      // Refresh upcoming events after creating a new one
      ref.refresh(upcomingEventsProvider);
      _loadEvents(); // Also refresh the calendar view
    }
  }
}

class Event {
  final String id;
  final String title;
  final String description;
  final Map<String, dynamic>? location;
  final bool isPrivate;
  final List<String> sharedWith;
  final DateTime date;
  final DateTime? endDate;
  final String creatorId;
  final String? creatorDisplayName;
  final EventCategory category;

  Event({
    required this.id,
    required this.title,
    required this.description,
    this.location,
    required this.isPrivate,
    required this.sharedWith,
    required this.date,
    this.endDate,
    required this.creatorId,
    this.creatorDisplayName,
    this.category = EventCategory.other,
  });

  String? get address {
    if (location == null) return null;
    final addr = location!['address'];
    if (addr is String) return addr;
    return null;
  }

  double? get lat {
    if (location == null) return null;
    final latVal = location!['lat'];
    if (latVal is double) return latVal;
    if (latVal is int) return latVal.toDouble();
    return null;
  }

  double? get lng {
    if (location == null) return null;
    final lngVal = location!['lng'];
    if (lngVal is double) return lngVal;
    if (lngVal is int) return lngVal.toDouble();
    return null;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'location': location,
      'isPrivate': isPrivate,
      'sharedWith': sharedWith,
      'date': date,
      'endDate': endDate,
      'creatorId': creatorId,
      'creatorDisplayName': creatorDisplayName,
      'category': category.name,
    };
  }

  factory Event.fromMap(Map<String, dynamic> map) {
    return Event(
      id: map['id'] as String,
      title: map['title'] as String,
      description: map['description'] as String,
      location: map['location'] as Map<String, dynamic>?,
      isPrivate: map['isPrivate'] as bool,
      sharedWith: List<String>.from(map['sharedWith'] as List),
      date: (map['date'] as Timestamp).toDate(),
      endDate: map['endDate'] != null ? (map['endDate'] as Timestamp).toDate() : null,
      creatorId: map['creatorId'] as String,
      creatorDisplayName: map['creatorDisplayName'] as String?,
      category: EventCategory.values.firstWhere(
        (e) => e.name == (map['category'] as String? ?? 'other'),
        orElse: () => EventCategory.other,
      ),
    );
  }
}