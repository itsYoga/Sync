import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import '../widgets/add_event_dialog.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/selected_place.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class ChatWithGeminiScreen extends StatefulWidget {
  const ChatWithGeminiScreen({super.key});

  @override
  State<ChatWithGeminiScreen> createState() => _ChatWithGeminiScreenState();
}

class _ChatWithGeminiScreenState extends State<ChatWithGeminiScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _sendMessage(String message) async {
    // Extract event details from the user's input before sending to Gemini
    final event = _parseEventFromUserInput(message);
    setState(() {
      _messages.add({'role': 'user', 'content': message});
      _isLoading = true;
    });
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    final model = GenerativeModel(model: 'gemini-1.5-flash-latest', apiKey: apiKey!);
    final chat = model.startChat();
    // Add a system prompt for more human-like, friendly responses
    final systemPrompt = Content.text(
      "You are a friendly event planning assistant. Reply in a conversational, human way, without markdown or asterisks. If the user asks to create an event, ask for any missing details in a natural way."
    );
    final content = Content.text(message);
    try {
      await chat.sendMessage(systemPrompt); // send system prompt first
      final response = await chat.sendMessage(content); // then send user message
      final reply = response.text ?? 'No response.';
      setState(() {
        _messages.add({'role': 'gemini', 'content': reply});
        _isLoading = false;
      });
      // If we extracted an event from the user's input, show the event dialog
      if (event != null) {
        _showEventDialog(event);
      }
    } catch (e) {
      setState(() {
        _messages.add({'role': 'gemini', 'content': 'Error: $e'});
        _isLoading = false;
      });
    }
  }

  // Improved event extraction from user input
  Map<String, dynamic>? _parseEventFromUserInput(String input) {
    String originalInputForDebug = input;
    String processingInput = input.toLowerCase().trim();

    // 1. Extract Privacy
    bool isPrivate = processingInput.contains('private');
    if (isPrivate) {
      processingInput = processingInput.replaceAll('private', '').trim();
    }

    // 2. Extract Date and Time
    DateTime? eventDate;
    TimeOfDay? eventTime;

    String? matchedDateString;
    String? matchedTimeString;

    // --- Date Extraction ---
    final datePatterns = {
      // Specific date formats first
      RegExp(r'\b(\d{4}-\d{1,2}-\d{1,2})\b'): (Match m) => DateFormat('yyyy-MM-dd').parse(m.group(1)!),
      RegExp(r'\b(\d{1,2}/\d{1,2}/\d{4})\b'): (Match m) => DateFormat('M/d/yyyy').parse(m.group(1)!),
      RegExp(r'\b(\d{1,2}/\d{1,2})\b(?!\s*pm|\s*am|:)'): (Match m) { // M/D (assumes current year), ensure not part of time
        final now = DateTime.now();
        return DateFormat('M/d/yyyy').parse('${m.group(1)!}/${now.year}');
      },
      RegExp(r'\btoday\b', caseSensitive: false): (Match m) => DateTime.now(),
      RegExp(r'\btomorrow\b', caseSensitive: false): (Match m) => DateTime.now().add(const Duration(days: 1)),
      // Basic "next Monday", etc.
      RegExp(r'next\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b', caseSensitive: false): (Match m) {
        final days = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
        final targetDayWd = days.indexOf(m.group(1)!.toLowerCase()) + 1;
        var date = DateTime.now().add(const Duration(days: 1)); // Start from tomorrow
        while (date.weekday != targetDayWd) {
          date = date.add(const Duration(days: 1));
        }
        // If 'next Monday' and today is Sunday, it means tomorrow. If today is Monday, it means Monday next week.
        // The above logic already ensures it's a future day.
        // To ensure it's truly *next* week if the day is within the current week:
        if (DateTime.now().weekday == targetDayWd && date.difference(DateTime.now()).inDays < 7) {
          // date = date.add(const Duration(days: 7)); // This was an error in previous thought process
        } else {
           var tempDate = DateTime.now();
           int daysToAdd = (targetDayWd + 7 - tempDate.weekday) % 7;
           if (daysToAdd == 0) daysToAdd = 7; // if it's same day of week, go to next week
           date = tempDate.add(Duration(days: daysToAdd));
        }
        return date;
      },
    };

    for (var entry in datePatterns.entries) {
      final pattern = entry.key;
      final parser = entry.value;
      final match = pattern.firstMatch(processingInput);
      if (match != null) {
        try {
          eventDate = parser(match);
          matchedDateString = match.group(0)!; // Full matched string for date
          break;
        } catch (_) {/* ignore parsing error, try next pattern */}
      }
    }

    // Remove identified date string from processingInput *after* finding it
    if (matchedDateString != null) {
      processingInput = processingInput.replaceFirst(RegExp(RegExp.escape(matchedDateString), caseSensitive: false), '').trim();
    }

    // --- Time Extraction ---
    final timeRegex = RegExp(r'\b(\d{1,2}(?::\d{2})?\s*(am|pm)|(\d{1,2}:\d{2}))\b', caseSensitive: false);
    final timeMatch = timeRegex.firstMatch(processingInput);
    if (timeMatch != null) {
      matchedTimeString = timeMatch.group(0)!; // Full matched string for time
      try {
        DateTime parsedDt;
        String timeStrForParsing = matchedTimeString.replaceAll(RegExp(r'\s+'), '').toLowerCase(); // "7 pm" -> "7pm"

        if (timeStrForParsing.contains('am') || timeStrForParsing.contains('pm')) {
          parsedDt = DateFormat('h:mma').parseLoose(timeStrForParsing);
           if (!matchedTimeString.contains(':') && (parsedDt.minute !=0) ){ // e.g. 7pm parsed as 7:00 AM by default by parseLoose without a minute
               // if 7pm was input, and parseLoose gave 7:30 for example, it's probably wrong, reset minutes
               // This is tricky. Let's re-parse hha for hour only if no colon
               if(!matchedTimeString.contains(':')){
                  var tempParsedHour = DateFormat('ha').parseLoose(timeStrForParsing);
                  parsedDt = DateTime(2000,1,1,tempParsedHour.hour, 0);
               } else {
                  parsedDt = DateFormat('h:mma').parseLoose(timeStrForParsing);
               }
          }

        } else if (matchedTimeString.contains(':')) {
          parsedDt = DateFormat('HH:mm').parse(matchedTimeString);
        } else { // Single number, e.g., "7" - assume hour, needs context for AM/PM
          int hour = int.parse(matchedTimeString);
          // Basic assumption: if < 8, assume PM, if > 17 assume PM (already 24h), else could be AM
          if (hour < 8 || (hour >= 12 && hour < 18) ) { // 1-7 -> PM, 12-17 -> as is
              if(hour < 12 && !(matchedTimeString.toLowerCase().contains('am') || matchedTimeString.toLowerCase().contains('pm'))) hour +=12;
          }
          parsedDt = DateTime(2000, 1, 1, hour % 24, 0); // Use dummy date
        }
        eventTime = TimeOfDay.fromDateTime(parsedDt);
      } catch (_) {/* ignore time parsing error */}
    }

    // Remove identified time string from processingInput
    if (matchedTimeString != null) {
      processingInput = processingInput.replaceFirst(RegExp(RegExp.escape(matchedTimeString), caseSensitive: false), '').trim();
    }
    
    // Combine date and time
    if (eventDate != null) {
      eventDate = DateTime(
        eventDate.year,
        eventDate.month,
        eventDate.day,
        eventTime?.hour ?? 18, // Default to 6 PM if only date found
        eventTime?.minute ?? 0,
      );
    } else {
      // If no date, cannot create event, but maybe Gemini can ask. For now, let's be strict.
      print('Debug Parser: No date found in "$originalInputForDebug"');
      return null;
    }

    // 3. Extract Location
    String? location;
    String? matchedLocationPhrase; // e.g., "at taipei 101"

    // Try to find location phrases like "at/in/near [location text]"
    // This regex tries to capture the preposition and the location text that follows.
    // It's greedy for the location part (.+).
    final locationRegex = RegExp(r'\b(at|in|near|@)\s+(.+)$', caseSensitive: false);
    final locMatch = locationRegex.firstMatch(processingInput);

    if (locMatch != null) {
      location = locMatch.group(2)?.trim(); // The text after "at/in/near"
      matchedLocationPhrase = locMatch.group(0); // The whole "at/in/near location" phrase
      if (location != null && location.isEmpty) location = null;
    }

    // Remove identified location phrase from processingInput
    if (matchedLocationPhrase != null) {
      processingInput = processingInput.replaceFirst(RegExp(RegExp.escape(matchedLocationPhrase), caseSensitive: false), '').trim();
    }
    
    processingInput = processingInput.replaceAll(RegExp(r'\s+'), ' ').trim(); // Normalize spaces

    // 4. Determine Title
    String title = processingInput;

    // More aggressive command/filler phrase removal from the beginning of the remaining string
    // Order matters: longer, more specific phrases first.
    final commandPrefixes = [
      RegExp(r"^(help\s+me\s+to\s+|help\s+me\s+)?(add|set|create|schedule|make|book|plan)\s+(an?\s+|the\s+)?event\s*(to|for|on|about|with)?\s*", caseSensitive: false),
      RegExp(r"^(i\s+want\s+to\s+|i'd\s+like\s+to\s+|can\s+you\s+(?:please\s+)?)?(add|set|create|schedule|make|book|plan)\s+(an?\s+|the\s+)?event\s*(to|for|on|about|with)?\s*", caseSensitive: false),
      RegExp(r"^(event|meeting|appointment|task)\s*[:\-]\s*", caseSensitive: false), // "event: ", "event - "
      RegExp(r"^(event|meeting|appointment|task)\s+(to|for|on|about|with)\s+", caseSensitive: false), // "event for "
      RegExp(r"^(to\s+)?(have|get|go\s+for|do|make|attend|join|organize|host)\s+(an?\s+|the\s+)?", caseSensitive: false), // "to have a", "have"
    ];

    for (var regex in commandPrefixes) {
      if (regex.hasMatch(title)) {
        title = title.replaceFirst(regex, '').trim();
      }
    }
    
    // Remove trailing prepositions if any were left (less common)
    title = title.replaceAll(RegExp(r"\s+(at|in|to|for|on|with)$", caseSensitive: false), "").trim();


    // If title is empty after stripping, use a generic title or what's in location
    if (title.isEmpty) {
      if (location != null && location.isNotEmpty) {
        title = "Event at $location";
      } else {
        title = "New Event"; // Fallback generic title
      }
    }

    // Final attempt to make title just the noun part for common phrases like "have dinner" -> "Dinner"
    final commonVerbPhrases = {
      RegExp(r"^(?:to\s+)?have\s+(?:an?\s+|the\s+)?(.+)", caseSensitive: false): (Match m) => m.group(1)!,
      RegExp(r"^(?:to\s+)?get\s+(?:an?\s+|the\s+)?(.+)", caseSensitive: false): (Match m) => m.group(1)!,
      RegExp(r"^(?:to\s+)?make\s+(?:an?\s+|the\s+)?(.+)", caseSensitive: false): (Match m) => m.group(1)!,
      RegExp(r"^(?:to\s+)?do\s+(?:an?\s+|the\s+)?(.+)", caseSensitive: false): (Match m) => m.group(1)!,
    };
    for (var entry in commonVerbPhrases.entries) {
        final match = entry.key.firstMatch(title);
        if (match != null) {
            String potentialTitle = entry.value(match).trim();
            // Only replace if the new title is reasonably shorter and seems like a noun phrase
            if (potentialTitle.isNotEmpty && potentialTitle.length < title.length && !potentialTitle.contains(RegExp(r"\s(at|in|to|for|on|with)$"))) {
                title = potentialTitle;
                break; 
            }
        }
    }


    // Capitalize first letter of the title
    if (title.isNotEmpty) {
      title = title[0].toUpperCase() + title.substring(1);
    }

    print('Original Input: "$originalInputForDebug"');
    print('Parsed Event -> Title: "$title", Date: $eventDate, Location: "$location", Private: $isPrivate');

    // 5. Validate and Return
    if (title.isNotEmpty && eventDate != null) {
      return {
        'title': title,
        'date': eventDate,
        'location': location, // Can be null, Gemini/dialog can ask for it
        'isPrivate': isPrivate,
      };
    }
    print('Debug Parser: Failed to extract enough info from "$originalInputForDebug"');
    return null;
  }

  void _showEventDialog(Map<String, dynamic> event) async {
    // If a location is present, search Google Places and let the user pick
    String? address = event['location'];
    double? lat;
    double? lng;
    SelectedPlace? selectedPlace;
    if (address != null && address.isNotEmpty) {
      // Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
          content: const Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Text("Searching location..."),
            ],
          ),
        ),
      );
      final apiKey = dotenv.env['GOOGLE_MAPS_API_KEY'];
      final url = Uri.parse('https://maps.googleapis.com/maps/api/place/textsearch/json?query=${Uri.encodeComponent(address)}&key=$apiKey');
      try {
        final response = await http.get(url);
        Navigator.of(context).pop(); // Remove loading dialog
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final results = List<Map<String, dynamic>>.from(data['results']);
          if (results.isNotEmpty) {
            // Let the user pick from the results
            final picked = await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (context) => SimpleDialog(
                title: const Text('Did you mean?', style: TextStyle(fontWeight: FontWeight.bold)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
                children: results.take(5).map((place) {
                  final name = place['name'] ?? 'Unknown place';
                  final formattedAddress = place['formatted_address'] ?? 'No address available';
                  return SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, place),
                    padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                    child: ListTile(
                      leading: Icon(Icons.place_outlined, color: Theme.of(context).colorScheme.primary),
                      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w500)),
                      subtitle: Text(formattedAddress, style: TextStyle(fontSize: 13, color: Colors.grey)),
                      contentPadding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
                    ),
                  );
                }).toList()
                ..add(
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, null),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12.0),
                      child: Text(
                        'Use "${event['location']}" as text',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).colorScheme.secondary),
                      ),
                    ),
                  ),
                ),
              ),
            );
            if (picked != null) {
              address = picked['formatted_address'] ?? address;
              lat = picked['geometry']['location']['lat']?.toDouble();
              lng = picked['geometry']['location']['lng']?.toDouble();
              selectedPlace = SelectedPlace(
                position: LatLng(lat!, lng!),
                address: address ?? 'Lat: ${lat.toStringAsFixed(5)}, Lng: ${lng.toStringAsFixed(5)}',
              );
            }
          }
        }
      } catch (e) {
        Navigator.of(context).pop();
      }
    }
    await showDialog(
      context: context,
      builder: (context) => AddEventDialog(
        initialTitle: event['title'],
        initialLocation: address,
        initialDate: event['date'],
        initialIsPrivate: event['isPrivate'] ?? false,
        initialSelectedPlace: selectedPlace,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat with Gemini')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12.0),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isUser = msg['role'] == 'user';
                final theme = Theme.of(context);
                final screenWidth = MediaQuery.of(context).size.width;
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Card(
                    elevation: 1.5,
                    color: isUser
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: isUser
                            ? const Radius.circular(16)
                            : const Radius.circular(4),
                        bottomRight: isUser
                            ? const Radius.circular(4)
                            : const Radius.circular(16),
                      ),
                    ),
                    margin: const EdgeInsets.symmetric(vertical: 5.0, horizontal: 8.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
                      constraints: BoxConstraints(maxWidth: screenWidth * 0.75),
                      child: Text(
                        msg['content'] ?? '',
                        style: TextStyle(
                          color: isUser
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onSurface,
                          fontSize: 15.5,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: CircularProgressIndicator(),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12.0, 8.0, 12.0, 12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: 'Ask Gemini to create an event...',
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainerLowest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24.0),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    ),
                    onSubmitted: (value) {
                      if (value.trim().isNotEmpty) {
                        _sendMessage(value.trim());
                        _controller.clear();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send_rounded),
                  color: Theme.of(context).colorScheme.primary,
                  iconSize: 28,
                  style: IconButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                    padding: const EdgeInsets.all(12),
                  ),
                  onPressed: () {
                    final value = _controller.text.trim();
                    if (value.isNotEmpty) {
                      _sendMessage(value);
                      _controller.clear();
                    }
                  },
                )
              ],
            ),
          )
        ],
      ),
    );
  }
} 