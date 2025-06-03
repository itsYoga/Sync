import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:google_fonts/google_fonts.dart';

const Color primaryAppColor = Colors.deepPurple;
const Color accentAppColor = Colors.pinkAccent;
const Color surfaceAppColor = Colors.white;
const Color cardAppColor = Color(0xFFF8F8F8);

class FriendEventsScreen extends StatefulWidget {
  final String friendUid;
  final String friendName;
  const FriendEventsScreen({super.key, required this.friendUid, required this.friendName});

  @override
  State<FriendEventsScreen> createState() => _FriendEventsScreenState();
}

class _FriendEventsScreenState extends State<FriendEventsScreen> {
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Map<DateTime, List<Map<String, dynamic>>> _events = {};

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    try {
      final eventsSnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.friendUid)
          .collection('events')
          .where('isPrivate', isEqualTo: false)
          .get();

      final events = eventsSnapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          'title': data['title'] ?? '',
          'description': data['description'] ?? '',
          'date': (data['date'] as Timestamp).toDate(),
          'endDate': data['endDate'] != null ? (data['endDate'] as Timestamp).toDate() : null,
          'location': data['location'],
          'isPrivate': data['isPrivate'] ?? false,
          'sharedWith': List<String>.from(data['sharedWith'] ?? []),
          'creatorId': data['creatorId'] ?? widget.friendUid,
        };
      }).toList();

      // Group events by date
      final groupedEvents = <DateTime, List<Map<String, dynamic>>>{};
      for (var event in events) {
        DateTime dayCursor = DateTime.utc(
          event['date'].year,
          event['date'].month,
          event['date'].day,
        );
        DateTime finalDay = event['endDate'] != null
            ? DateTime.utc(
                event['endDate'].year,
                event['endDate'].month,
                event['endDate'].day,
              )
            : dayCursor;

        while (!dayCursor.isAfter(finalDay)) {
          if (groupedEvents[dayCursor] == null) {
            groupedEvents[dayCursor] = [];
          }
          if (!groupedEvents[dayCursor]!.any((e) => e['id'] == event['id'])) {
            groupedEvents[dayCursor]!.add(event);
          }
          dayCursor = dayCursor.add(const Duration(days: 1));
        }
      }

      setState(() {
        _events = groupedEvents;
      });
    } catch (e) {
      rethrow;
    }
  }

  List<Map<String, dynamic>> _getEventsForDay(DateTime day) {
    final key = DateTime.utc(day.year, day.month, day.day);
    return _events[key] ?? [];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.background,
      appBar: AppBar(
        title: Text("${widget.friendName}'s Public Events", 
          style: GoogleFonts.lato(fontWeight: FontWeight.bold)),
        backgroundColor: surfaceAppColor,
        elevation: 1,
        actions: [
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
            child: TableCalendar(
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
                    label: Text('${_getEventsForDay(_selectedDay!).length} events', 
                      style: GoogleFonts.lato(color: Colors.white)),
                    backgroundColor: accentAppColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  )
              ],
            ),
          ),
          Expanded(
            child: _selectedDay == null
                ? Center(child: Text('Select a day to view events', 
                    style: GoogleFonts.lato(fontSize: 16, color: Colors.grey)))
                : _getEventsForDay(_selectedDay!).isEmpty
                  ? Center(child: Text('No events for this day 🎉', 
                      style: GoogleFonts.lato(fontSize: 16, color: Colors.grey)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      itemCount: _getEventsForDay(_selectedDay!).length,
                      itemBuilder: (context, index) {
                        final event = _getEventsForDay(_selectedDay!)[index];
                        return Card(
                          elevation: 2,
                          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          color: cardAppColor,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            leading: Icon(
                              event['isPrivate'] ? Icons.lock_outline : Icons.event_available_outlined,
                              color: event['isPrivate'] ? Colors.orangeAccent : primaryAppColor,
                            ),
                            title: Text(event['title'], 
                              style: GoogleFonts.lato(fontWeight: FontWeight.w600)),
                            subtitle: event['description'].isNotEmpty
                                ? Text(event['description'], 
                                    style: GoogleFonts.lato(), 
                                    maxLines: 2, 
                                    overflow: TextOverflow.ellipsis)
                                : null,
                            onTap: () {
                              showDialog(
                                context: context, 
                                builder: (ctx) => AlertDialog(
                                  title: Text(event['title'], 
                                    style: GoogleFonts.lato(
                                      color: primaryAppColor, 
                                      fontWeight: FontWeight.bold
                                    )
                                  ),
                                  content: SingleChildScrollView(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text("Date: ${DateFormat('MMM dd, yyyy').format(event['date'])}", 
                                          style: GoogleFonts.lato()
                                        ),
                                        const SizedBox(height: 8),
                                        Text("Description:", 
                                          style: GoogleFonts.lato(fontWeight: FontWeight.bold)
                                        ),
                                        Text(
                                          event['description'].isNotEmpty 
                                            ? event['description'] 
                                            : "No description.", 
                                          style: GoogleFonts.lato()
                                        ),
                                        if (event['location'] != null) ...[
                                          const SizedBox(height: 8),
                                          Text("Location:", 
                                            style: GoogleFonts.lato(fontWeight: FontWeight.bold)
                                          ),
                                          Text(
                                            event['location'] is Map 
                                              ? event['location']['address'] ?? 'No address'
                                              : event['location'].toString(),
                                            style: GoogleFonts.lato()
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(ctx).pop(),
                                      child: Text("Close", style: GoogleFonts.lato())
                                    )
                                  ],
                                )
                              );
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
} 