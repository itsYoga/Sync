import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../screens/map_screen.dart';
import '../models/selected_place.dart';
import 'package:google_places_flutter/google_places_flutter.dart';
import '../screens/calendar_screen.dart';

class AddEventDialog extends StatefulWidget {
  final String? initialTitle;
  final String? initialDescription;
  final String? initialLocation;
  final DateTime? initialDate;
  final DateTime? initialEndDate;
  final bool initialIsPrivate;
  final List<Map<String, dynamic>> friendsList;
  final List<String> initialSelectedFriendUids;
  final SelectedPlace? initialSelectedPlace;
  final EventCategory? initialCategory;

  const AddEventDialog({
    super.key,
    this.initialTitle,
    this.initialDescription,
    this.initialLocation,
    this.initialDate,
    this.initialEndDate,
    this.initialIsPrivate = false,
    this.friendsList = const [],
    this.initialSelectedFriendUids = const [],
    this.initialSelectedPlace,
    this.initialCategory,
  });

  @override
  State<AddEventDialog> createState() => _AddEventDialogState();
}

class _AddEventDialogState extends State<AddEventDialog> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  DateTime? _selectedEndDate;
  bool _isPrivate = false;
  List<String> _selectedFriendUids = [];
  SelectedPlace? _selectedPlaceDetails;
  bool _isLoading = false;
  EventCategory _selectedCategory = EventCategory.other;

  @override
  void initState() {
    super.initState();
    _titleController.text = widget.initialTitle ?? '';
    _descriptionController.text = widget.initialDescription ?? '';
    _locationController.text = widget.initialLocation ?? '';
    _selectedDate = widget.initialDate ?? DateTime.now();
    _selectedEndDate = widget.initialEndDate;
    _isPrivate = widget.initialIsPrivate;
    _selectedFriendUids = List<String>.from(widget.initialSelectedFriendUids);
    _selectedPlaceDetails = widget.initialSelectedPlace;
    _selectedCategory = widget.initialCategory ?? EventCategory.other;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _pickDate(BuildContext context, bool isStartDate) async {
    DateTime initialDatePickerDate =
        isStartDate ? _selectedDate : (_selectedEndDate ?? _selectedDate.add(const Duration(hours: 1)));
    if (!isStartDate && _selectedEndDate == null) {
      initialDatePickerDate = _selectedDate.add(const Duration(days: 1));
    }

    final date = await showDatePicker(
      context: context,
      initialDate: initialDatePickerDate,
      firstDate: isStartDate ? DateTime(2000) : _selectedDate,
      lastDate: DateTime(2101),
      builder: (context, child) {
        return Theme(
          data: ThemeData.light().copyWith(
            colorScheme: const ColorScheme.light(primary: Colors.deepPurple),
          ),
          child: child!,
        );
      },
    );

    if (date != null) {
      final TimeOfDay initialTime = TimeOfDay.fromDateTime(
          isStartDate ? _selectedDate : (_selectedEndDate ?? _selectedDate.add(const Duration(hours: 1))));

      final time = await showTimePicker(
        context: context,
        initialTime: initialTime,
      );

      if (time != null) {
        setState(() {
          if (isStartDate) {
            _selectedDate = DateTime(
                date.year, date.month, date.day, time.hour, time.minute);
            if (_selectedEndDate != null && _selectedEndDate!.isBefore(_selectedDate)) {
              _selectedEndDate = _selectedDate.add(const Duration(hours: 1));
            }
          } else {
            _selectedEndDate = DateTime(
                date.year, date.month, date.day, time.hour, time.minute);
          }
        });
      }
    }
  }

  Future<void> _selectLocationFromMap() async {
    final result = await Navigator.push<SelectedPlace?>(
      context,
      MaterialPageRoute(
        builder: (context) => MapScreen(initialPlace: _selectedPlaceDetails),
      ),
    );
    if (result != null) {
      setState(() {
        _selectedPlaceDetails = result;
        _locationController.text = result.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Defensive check for missing API key
    if ((dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '').isEmpty) {
      return AlertDialog(
        title: Text('Configuration Error'),
        content: Text('Google Maps API key is missing. Please check your .env file.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('OK'),
          ),
        ],
      );
    }
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        'Add New Event',
        style: GoogleFonts.lato(fontWeight: FontWeight.bold, color: Colors.deepPurple, fontSize: 20),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _titleController,
              decoration: InputDecoration(
                labelText: 'Title',
                labelStyle: GoogleFonts.lato(),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.deepPurple),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              decoration: InputDecoration(
                labelText: 'Description',
                labelStyle: GoogleFonts.lato(),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.deepPurple),
                ),
              ),
              maxLines: 3,
              minLines: 1,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _locationController,
              readOnly: true,
              decoration: InputDecoration(
                labelText: 'Location',
                labelStyle: GoogleFonts.lato(),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.deepPurple),
                ),
                prefixIcon: Icon(Icons.location_on_outlined, color: Colors.grey[700]),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.map),
                  onPressed: _selectLocationFromMap,
                ),
              ),
              onTap: _selectLocationFromMap,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.calendar_today, size: 20, color: Colors.grey[700]),
                const SizedBox(width: 8),
                Text('Start Date: ', style: GoogleFonts.lato(fontSize: 16)),
                Expanded(
                  child: TextButton(
                    onPressed: () => _pickDate(context, true),
                    child: Text(
                      DateFormat('MMM dd, yyyy hh:mm a').format(_selectedDate),
                      style: GoogleFonts.lato(
                          color: Colors.deepPurple,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Icon(Icons.calendar_today_outlined, size: 20, color: Colors.grey[700]),
                const SizedBox(width: 8),
                Text('End Date:   ', style: GoogleFonts.lato(fontSize: 16)),
                Expanded(
                  child: TextButton(
                    onPressed: () => _pickDate(context, false),
                    child: Text(
                      _selectedEndDate != null
                          ? DateFormat('MMM dd, yyyy hh:mm a').format(_selectedEndDate!)
                          : 'Set End Date (Optional)',
                      style: GoogleFonts.lato(
                          color: Colors.deepPurple,
                          fontWeight: _selectedEndDate != null ? FontWeight.bold : FontWeight.normal),
                    ),
                  ),
                ),
                if (_selectedEndDate != null)
                  IconButton(
                    icon: Icon(Icons.clear, size: 18, color: Colors.grey[600]),
                    tooltip: 'Clear End Date',
                    onPressed: () => setState(() => _selectedEndDate = null),
                  )
              ],
            ),
            Row(
              children: [
                Icon(_isPrivate ? Icons.lock_outline : Icons.lock_open_outlined, size: 20, color: Colors.grey[700]),
                const SizedBox(width: 8),
                Text('Private Event: ', style: GoogleFonts.lato(fontSize: 16)),
                Switch(
                  value: _isPrivate,
                  onChanged: (value) => setState(() => _isPrivate = value),
                  activeColor: Colors.deepPurple,
                ),
              ],
            ),
            if (widget.friendsList.isNotEmpty && !_isPrivate) ...[
              const SizedBox(height: 10),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Invite Friends:',
                  style: GoogleFonts.lato(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              ...widget.friendsList.map((friend) {
                final bool isSelected = _selectedFriendUids.contains(friend['uid']);
                return CheckboxListTile(
                  value: isSelected,
                  title: Text(
                    friend['displayName'] ?? friend['email'] ?? 'Unknown',
                    style: GoogleFonts.lato(),
                  ),
                  onChanged: (checked) {
                    setState(() {
                      if (checked == true) {
                        if (!_selectedFriendUids.contains(friend['uid'])) {
                          _selectedFriendUids.add(friend['uid']);
                        }
                      } else {
                        _selectedFriendUids.remove(friend['uid']);
                      }
                    });
                  },
                  activeColor: Colors.deepPurple,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                );
              }).toList(),
            ],
            if (widget.friendsList.isEmpty && !_isPrivate)
              Padding(
                padding: const EdgeInsets.only(top: 10.0),
                child: Text(
                  'You have no friends to invite yet.',
                  style: GoogleFonts.lato(fontStyle: FontStyle.italic, color: Colors.grey),
                ),
              ),
            if (_isPrivate && widget.friendsList.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10.0),
                child: Text(
                  'Friend invitations are disabled for private events.',
                  style: GoogleFonts.lato(fontStyle: FontStyle.italic, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 16),
            Text('Category', style: GoogleFonts.lato(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: EventCategory.values.map((category) {
                final isSelected = category == _selectedCategory;
                return ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(category.icon, size: 16, color: isSelected ? Colors.white : category.color),
                      const SizedBox(width: 4),
                      Text(category.displayName, style: GoogleFonts.lato(
                        color: isSelected ? Colors.white : Colors.black87,
                      )),
                    ],
                  ),
                  selected: isSelected,
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _selectedCategory = category;
                      });
                    }
                  },
                  backgroundColor: Colors.white,
                  selectedColor: category.color,
                  side: BorderSide(color: category.color),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: GoogleFonts.lato(color: Colors.grey[700])),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple),
          onPressed: () async {
            if (_titleController.text.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Title cannot be empty.')),
              );
              return;
            }
            if (_selectedEndDate != null && _selectedEndDate!.isBefore(_selectedDate)) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('End date cannot be before start date.')),
              );
              return;
            }

            final currentUser = FirebaseAuth.instance.currentUser;
            if (currentUser == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('You need to be logged in to save events.')),
              );
              return;
            }

            try {
              Map<String, dynamic>? locationMapForSave;
              if (_selectedPlaceDetails != null) {
                locationMapForSave = {
                  'address': _selectedPlaceDetails!.address,
                  'lat': _selectedPlaceDetails!.position.latitude,
                  'lng': _selectedPlaceDetails!.position.longitude,
                };
              } else if (_locationController.text.isNotEmpty) {
                locationMapForSave = {
                  'address': _locationController.text,
                  'lat': null,
                  'lng': null,
                };
              } else {
                locationMapForSave = null;
              }

              // Save event with full location details
              final eventData = {
                'title': _titleController.text,
                'description': _descriptionController.text,
                'location': locationMapForSave,
                'date': Timestamp.fromDate(_selectedDate),
                'endDate': _selectedEndDate != null ? Timestamp.fromDate(_selectedEndDate!) : null,
                'isPrivate': _isPrivate,
                'sharedWith': _isPrivate ? [] : _selectedFriendUids,
                'createdAt': FieldValue.serverTimestamp(),
                'creatorId': currentUser.uid,
                'category': _selectedCategory.name,
              };

              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(currentUser.uid)
                  .collection('events')
                  .add(eventData);

              if (mounted) {
                Navigator.of(context).pop(eventData);
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to save event: $e')),
                );
              }
            }
          },
          child: Text(
            'Add',
            style: GoogleFonts.lato(color: Colors.white),
          ),
        ),
      ],
    );
  }
} 