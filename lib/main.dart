import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'screens/calendar_screen.dart';
import 'screens/friends_screen.dart';
import 'screens/conversations_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/event_requests_screen.dart';
import 'package:intl/intl.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../screens/map_screen.dart';
import '../models/selected_place.dart';
import 'widgets/add_event_dialog.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:convert';

// User state provider
final userProvider = StateProvider<User?>((ref) => null);

// Add this provider for upcoming events
final upcomingEventsProvider = StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    return Stream.value([]);
  }

  // Get the start of today to filter events from today onwards
  final now = DateTime.now();
  final startOfToday = DateTime(now.year, now.month, now.day);

  // Combine streams of created events and accepted invitations
  return Rx.combineLatest2(
    // Stream of events created by the user
    FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('events')
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfToday))
        .orderBy('date', descending: false)
        .snapshots(),
    
    // Stream of accepted invitations
    FirebaseFirestore.instance
        .collection('eventInvitations')
        .where('invitedUserId', isEqualTo: user.uid)
        .where('status', isEqualTo: 'accepted')
        .snapshots(),
    
    (QuerySnapshot createdEventsSnapshot, QuerySnapshot invitationsSnapshot) async {
      List<Map<String, dynamic>> allEvents = [];
      
      // Add created events
      for (var doc in createdEventsSnapshot.docs) {
        allEvents.add({
          'id': doc.id,
          'creatorId': user.uid,
          'isCreator': true,
          ...doc.data() as Map<String, dynamic>,
        });
      }
      
      // Add events from accepted invitations
      for (var inviteDoc in invitationsSnapshot.docs) {
        final inviteData = inviteDoc.data() as Map<String, dynamic>;
        final String eventId = inviteData['eventId'];
        final String creatorId = inviteData['creatorId'];
        
        try {
          final eventDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(creatorId)
              .collection('events')
              .doc(eventId)
              .get();
              
          if (eventDoc.exists) {
            final eventData = eventDoc.data()!;
            final eventDate = (eventData['date'] as Timestamp).toDate();
            
            // Only include future events
            if (eventDate.isAfter(startOfToday)) {
              allEvents.add({
                'id': eventId,
                'creatorId': creatorId,
                'isCreator': false,
                'invitationId': inviteDoc.id,
                'creatorDisplayName': inviteData['creatorDisplayName'],
                ...eventData,
              });
            }
          }
        } catch (e) {
          print('Error fetching invited event: $e');
        }
      }
      
      // Sort all events by date
      allEvents.sort((a, b) {
        final dateA = (a['date'] as Timestamp).toDate();
        final dateB = (b['date'] as Timestamp).toDate();
        return dateA.compareTo(dateB);
      });
      
      // Return only the next 3 upcoming events
      return allEvents.take(3).toList();
    },
  ).asyncMap((future) => future);
});

// Add this provider for pending invitations
final pendingInvitationsProvider = StreamProvider.autoDispose<int>((ref) {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    return Stream.value(0);
  }

  return FirebaseFirestore.instance
      .collection('eventInvitations')
      .where('invitedUserId', isEqualTo: user.uid)
      .where('status', isEqualTo: 'pending')
      .snapshots()
      .map((snapshot) => snapshot.docs.length);
});

// Add this provider for friends list (needed for event sharing)
final friendsListProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) return Stream.value([]);

  return FirebaseFirestore.instance
      .collection('users')
      .doc(currentUser.uid)
      .snapshots()
      .asyncMap((userDoc) async {
        if (!userDoc.exists || userDoc.data() == null) return [];

        final List<String> friendUids = List<String>.from(userDoc.data()?['friendUids'] ?? userDoc.data()?['friends'] ?? []);
        if (friendUids.isEmpty) return [];

        List<Map<String, dynamic>> friendsList = [];
        for (String uid in friendUids) {
          final friendDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
          if (friendDoc.exists) {
            friendsList.add({
              'uid': uid,
              'displayName': friendDoc.data()?['displayName'] ?? 'Unknown Friend',
              'photoURL': friendDoc.data()?['photoURL'],
              'email': friendDoc.data()?['email'] ?? '',
            });
          }
        }
        return friendsList;
      });
});

class OfflineSyncService {
  final FirebaseFirestore _firestore;
  final SharedPreferences _prefs;
  final Connectivity _connectivity;
  bool _isOnline = true;

  OfflineSyncService(this._firestore, this._prefs, this._connectivity) {
    _initConnectivity();
  }

  void _initConnectivity() {
    _connectivity.onConnectivityChanged.listen((ConnectivityResult result) {
      _isOnline = result != ConnectivityResult.none;
      if (_isOnline) {
        _syncPendingChanges();
      }
    });
  }

  Future<void> _syncPendingChanges() async {
    final pendingChanges = _prefs.getStringList('pending_changes') ?? [];
    for (final change in pendingChanges) {
      final data = Map<String, dynamic>.from(
        Map<String, dynamic>.from(
          const JsonDecoder().convert(change),
        ),
      );
      try {
        await _firestore
            .collection(data['collection'])
            .doc(data['document'])
            .set(data['data'], SetOptions(merge: true));
        pendingChanges.remove(change);
      } catch (e) {
        print('Error syncing change: $e');
      }
    }
    await _prefs.setStringList('pending_changes', pendingChanges);
  }

  Future<void> saveOffline(String collection, String document, Map<String, dynamic> data) async {
    if (!_isOnline) {
      final pendingChanges = _prefs.getStringList('pending_changes') ?? [];
      pendingChanges.add(const JsonEncoder().convert({
        'collection': collection,
        'document': document,
        'data': data,
      }));
      await _prefs.setStringList('pending_changes', pendingChanges);
    } else {
      await _firestore.collection(collection).doc(document).set(data, SetOptions(merge: true));
    }
  }

  Future<void> deleteOffline(String collection, String document) async {
    if (!_isOnline) {
      final pendingChanges = _prefs.getStringList('pending_changes') ?? [];
      pendingChanges.add(const JsonEncoder().convert({
        'collection': collection,
        'document': document,
        'delete': true,
      }));
      await _prefs.setStringList('pending_changes', pendingChanges);
    } else {
      await _firestore.collection(collection).doc(document).delete();
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  try {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  } catch (e) {
    if (e.toString().contains('duplicate-app')) {
      // App already initialized, continue
    } else {
      // In a real app, you might want to log this error more formally
      // For now, rethrowing is fine for debugging or if a higher-level handler exists
      rethrow;
    }
  }

  final prefs = await SharedPreferences.getInstance();
  final connectivity = Connectivity();
  final offlineSync = OfflineSyncService(
    FirebaseFirestore.instance,
    prefs,
    connectivity,
  );

  // Enable offline persistence
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );

  runApp(
    const ProviderScope(
      child: AuthStateListener(
      child: MyApp(),
      ),
    ),
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SyncUp Social',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.light,
        ),
        textTheme: GoogleFonts.interTextTheme(
          Theme.of(context).textTheme,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.dark,
        ),
        textTheme: GoogleFonts.interTextTheme(
          Theme.of(context).textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      home: const AuthWrapper(),
    );
  }
}

class AuthWrapper extends ConsumerWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProvider);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: user == null
          ? const LoginScreen(key: ValueKey('login'))
          : const MainScreen(key: ValueKey('main')),
    );
  }
}

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).colorScheme.primary.withOpacity(0.1),
              Theme.of(context).colorScheme.surface,
            ],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.calendar_month,
                  size: 80,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  'Welcome to SyncUp',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Connect and coordinate with friends',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withOpacity(0.7),
                      ),
                ),
                const SizedBox(height: 40),
                ElevatedButton.icon(
                  onPressed: () => AuthService.signIn(context),
                  icon: const Icon(Icons.login),
                  label: const Text('Sign In'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => AuthService.signUp(context),
                  icon: const Icon(Icons.person_add),
                  label: const Text('Sign Up'),
                   style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => AuthService.signInWithGoogle(context),
                  icon: Image.network(
                    'https://www.google.com/favicon.ico',
                    height: 20,
                    errorBuilder: (context, error, stackTrace) => const Icon(Icons.g_mobiledata, size: 24),
                  ),
                  label: const Text('Sign in with Google'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- MainScreen and its new helper widgets ---
class _HomeScreenContent extends ConsumerStatefulWidget {
  const _HomeScreenContent();

  @override
  ConsumerState<_HomeScreenContent> createState() => _HomeScreenContentState();
}

class _HomeScreenContentState extends ConsumerState<_HomeScreenContent> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleRefresh() async {
    // Refresh the upcomingEventsProvider
    await ref.refresh(upcomingEventsProvider.future);
    // Also refresh pending invitations if needed
    await ref.refresh(pendingInvitationsProvider.future);
  }

  Future<void> _showNewEventDialog() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const AddEventDialog(),
    );

    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Event created successfully!')),
      );
      // Refresh upcoming events after creating a new one
      ref.refresh(upcomingEventsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    final theme = Theme.of(context);
    final photoUrl = user?.photoURL;
    final upcomingEventsAsyncValue = ref.watch(upcomingEventsProvider);
    final pendingInvitationsAsyncValue = ref.watch(pendingInvitationsProvider);

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            theme.colorScheme.primary.withOpacity(0.05),
            theme.colorScheme.surface.withOpacity(0.5),
            theme.colorScheme.surface,
          ],
          stops: const [0.0, 0.3, 1.0]
        ),
      ),
      child: RefreshIndicator(
        onRefresh: _handleRefresh,
        color: theme.colorScheme.primary,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 20),
                CircleAvatar(
                  radius: 50,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  backgroundImage: (photoUrl != null && photoUrl.isNotEmpty)
                      ? NetworkImage(photoUrl)
                      : null,
                  child: (photoUrl == null || photoUrl.isEmpty)
                      ? Text(
                          user?.displayName?.substring(0, 1).toUpperCase() ??
                          user?.email?.substring(0, 1).toUpperCase() ??
                          'U',
                          style: theme.textTheme.headlineLarge?.copyWith(
                              color: theme.colorScheme.onPrimaryContainer))
                      : null,
                ),
                const SizedBox(height: 16),
                Text(
                  'Welcome back,',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.8),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  user?.displayName ?? user?.email ?? 'User',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  DateFormat('EEEE, MMMM d').format(DateTime.now()),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
                const SizedBox(height: 32),

                // --- Quick Actions Section ---
                Card(
                  elevation: 1,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Quick Actions',
                              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            StreamBuilder<QuerySnapshot>(
                              stream: FirebaseFirestore.instance
                                  .collection('eventInvitations')
                                  .where('creatorId', isEqualTo: user?.uid)
                                  .where('status', isEqualTo: 'change_requested')
                                  .snapshots(),
                              builder: (context, snapshot) {
                                final requestCount = snapshot.data?.docs.length ?? 0;
                                if (requestCount == 0) return const SizedBox.shrink();
                                
                                return TextButton.icon(
                                  onPressed: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => const EventRequestsScreen(),
                                      ),
                                    );
                                  },
                                  icon: const Icon(Icons.event_available),
                                  label: Text('$requestCount Request${requestCount == 1 ? '' : 's'}'),
                                  style: TextButton.styleFrom(
                                    foregroundColor: theme.colorScheme.primary,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _QuickActionButton(
                              icon: Icons.add_circle_outline,
                              label: 'New Event',
                              onTap: _showNewEventDialog,
                            ),
                            _QuickActionButton(
                              icon: Icons.calendar_today_outlined,
                              label: 'Calendar',
                              onTap: () {
                                final mainScreenState = context.findAncestorStateOfType<_MainScreenState>();
                                if (mainScreenState != null && mainScreenState.mounted) {
                                  mainScreenState._onItemTapped(1);
                                }
                              },
                            ),
                            _QuickActionButton(
                              icon: Icons.chat_bubble_outline_rounded,
                              label: 'Chats',
                              onTap: () {
                                final mainScreenState = context.findAncestorStateOfType<_MainScreenState>();
                                if (mainScreenState != null && mainScreenState.mounted) {
                                  mainScreenState._onItemTapped(3);
                                }
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // --- Pending Invitations Section ---
                pendingInvitationsAsyncValue.when(
                  data: (count) {
                    if (count == 0) return const SizedBox.shrink();
                    return Card(
                      elevation: 1,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.primaryContainer,
                          child: Icon(Icons.mail_outline, color: theme.colorScheme.primary),
                        ),
                        title: Text('You have $count pending invitation${count == 1 ? '' : 's'}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          // TODO: Navigate to invitations screen
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Invitations screen coming soon!')),
                          );
                        },
                      ),
                    );
                  },
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                ),
                if (pendingInvitationsAsyncValue.valueOrNull != null &&
                    pendingInvitationsAsyncValue.valueOrNull! > 0)
                  const SizedBox(height: 24),

                // --- Upcoming Events Section ---
                Text(
                  'Your Upcoming Events',
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                upcomingEventsAsyncValue.when(
                  data: (events) {
                    if (events.isEmpty) {
                      return Card(
                        elevation: 1,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
                          child: Column(
                            children: [
                              Icon(Icons.event_available_outlined, size: 40, color: Colors.grey[400]),
                              const SizedBox(height: 8),
                              Text(
                                'No upcoming events for now!',
                                style: theme.textTheme.titleMedium?.copyWith(color: Colors.grey[600]),
                              ),
                              Text(
                                'Enjoy your free time or plan something new.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey[500]),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    return Column(
                      children: events.map((event) => Card(
                        elevation: 1.5,
                        margin: const EdgeInsets.symmetric(vertical: 6.0),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        child: ListTile(
                          leading: Icon(
                            event['isPrivate'] == true ? Icons.lock_outline : Icons.event_outlined,
                            color: theme.colorScheme.primary,
                          ),
                          title: Text(
                            event['title'] ?? 'No Title',
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "${DateFormat.MMMd().format((event['date'] as Timestamp).toDate())}, "
                                "${DateFormat.jm().format((event['date'] as Timestamp).toDate())}"
                                "${event['endDate'] != null ? " - ${DateFormat.jm().format((event['endDate'] as Timestamp).toDate())}" : ""}",
                              ),
                              if (!(event['isCreator'] ?? false))
                                Text(
                                  'Created by ${event['creatorDisplayName'] ?? 'Unknown'}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface.withOpacity(0.7),
                                  ),
                                ),
                            ],
                          ),
                          trailing: PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            onSelected: (value) async {
                              if (value == 'view') {
                                final mainScreenState = context.findAncestorStateOfType<_MainScreenState>();
                                if (mainScreenState != null && mainScreenState.mounted) {
                                  mainScreenState._onItemTapped(1);
                                  CalendarScreen.updateDate((event['date'] as Timestamp).toDate());
                                }
                              } else if (value == 'request_change' && !(event['isCreator'] ?? false)) {
                                // Show dialog to request change
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
                                    await FirebaseFirestore.instance
                                        .collection('eventInvitations')
                                        .doc(event['invitationId'])
                                        .update({
                                      'status': 'change_requested',
                                      'changeRequestReason': reason,
                                      'changeRequestedAt': FieldValue.serverTimestamp(),
                                    });

                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Change request sent to event creator')),
                                      );
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Error sending request: $e')),
                                      );
                                    }
                                  }
                                }
                              }
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: 'view',
                                child: Row(
                                  children: [
                                    Icon(Icons.visibility_outlined),
                                    SizedBox(width: 8),
                                    Text('View Details'),
                                  ],
                                ),
                              ),
                              if (!(event['isCreator'] ?? false))
                                const PopupMenuItem(
                                  value: 'request_change',
                                  child: Row(
                                    children: [
                                      Icon(Icons.edit_calendar),
                                      SizedBox(width: 8),
                                      Text('Request Change'),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          onTap: () {
                            // Intentionally left blank as per user request
                          },
                        ),
                      )).toList(),
                    );
                  },
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20.0),
                    child: CircularProgressIndicator(),
                  ),
                  error: (err, stack) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20.0),
                    child: Text('Error loading events: $err', style: TextStyle(color: theme.colorScheme.error)),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: theme.colorScheme.primary),
            const SizedBox(height: 8),
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileScreenPlaceholder extends StatelessWidget {
  const _ProfileScreenPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.person, size: 80, color: Colors.grey),
          const SizedBox(height: 20),
          const Text(
            'Profile Screen',
            style: TextStyle(fontSize: 24, color: Colors.grey),
          ),
          const SizedBox(height: 20),
          Text('Coming soon!', style: TextStyle(color: Colors.grey[600])),
          const SizedBox(height: 40),
          ElevatedButton.icon(
            icon: const Icon(Icons.logout_outlined),
            label: const Text('Sign Out'),
            onPressed: () => AuthService.signOut(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            ),
          )
        ],
      ),
    );
  }
}


class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  int _selectedIndex = 0;

  static const List<Widget> _pages = <Widget>[
    _HomeScreenContent(),
    CalendarScreen(),
    FriendsScreen(),
    ConversationsScreen(),
    ProfileScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  String _getTitleForIndex(int index) {
    switch (index) {
      case 0:
        return 'SyncUp';
      case 1:
        return 'My Calendar';
      case 2:
        return 'My Friends';
      case 3:
        return 'Conversations'; 
      case 4:
        return 'My Profile';
      default:
        return 'SyncUp Social';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_getTitleForIndex(_selectedIndex), style: GoogleFonts.pacifico()),
        actions: [
          if (_selectedIndex == 4)
            IconButton(
              icon: Icon(Icons.settings_outlined, color: Theme.of(context).colorScheme.onPrimaryContainer),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Settings coming soon!'))
                );
              },
              tooltip: 'Settings',
            )
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem( // Home
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem( // Calendar
            icon: Icon(Icons.calendar_month_outlined),
            activeIcon: Icon(Icons.calendar_month),
            label: 'Calendar',
          ),
          BottomNavigationBarItem( // Friends
            icon: Icon(Icons.group_outlined),
            activeIcon: Icon(Icons.group),
            label: 'Friends',
          ),
          BottomNavigationBarItem( // Conversations (was Gemini)
            icon: Icon(Icons.chat_bubble_outline_rounded), // Changed icon
            activeIcon: Icon(Icons.chat_bubble_rounded),   // Changed icon
            label: 'Chats', // Changed label
          ),
          BottomNavigationBarItem( // Profile
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
        showUnselectedLabels: true,
      ),
    );
  }
}


// AuthService class (assuming it's mostly the same)
class AuthService {
  static Future<void> signIn(BuildContext context) async {
    final TextEditingController emailController = TextEditingController();
    final TextEditingController passwordController = TextEditingController();
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign In'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: emailController,
              decoration: const InputDecoration(labelText: 'Email'),
              keyboardType: TextInputType.emailAddress,
            ),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              try {
                final userCredential = await FirebaseAuth.instance
                    .signInWithEmailAndPassword(
                  email: emailController.text.trim(),
                  password: passwordController.text,
                );
                // Access the userProvider via ProviderScope.containerOf
                ProviderScope.containerOf(context)
                    .read(userProvider.notifier)
                    .state = userCredential.user;

                if (context.mounted) {
                  Navigator.pop(context); // Close dialog
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Signed in successfully!')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: ${e.toString()}')),
                  );
                }
              }
            },
            child: const Text('Sign In'),
          ),
        ],
      ),
    );
  }

  static Future<void> signInWithGoogle(BuildContext context) async {
    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) return; // User cancelled the sign-in

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential = 
          await FirebaseAuth.instance.signInWithCredential(credential);
      
      if (userCredential.user != null) {
        // Save or update user data in Firestore
        await FirebaseFirestore.instance
            .collection('users')
            .doc(userCredential.user!.uid)
            .set({
          'email': userCredential.user!.email,
          'displayName': userCredential.user!.displayName,
          'photoURL': userCredential.user!.photoURL,
          'lastSignIn': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)); // Use merge to avoid overwriting existing fields like 'createdAt'

        ProviderScope.containerOf(context)
            .read(userProvider.notifier)
            .state = userCredential.user;
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Signed in with Google successfully!')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error signing in with Google: ${e.toString()}')),
        );
      }
    }
  }

   static Future<void> signUp(BuildContext context) async {
    final TextEditingController emailController = TextEditingController();
    final TextEditingController passwordController = TextEditingController();
    final TextEditingController nameController = TextEditingController();
    
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign Up'),
        content: SingleChildScrollView( // Added for smaller screens
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Full Name'),
                textCapitalization: TextCapitalization.words,
            ),
            TextField(
              controller: emailController,
              decoration: const InputDecoration(labelText: 'Email'),
              keyboardType: TextInputType.emailAddress,
            ),
            TextField(
              controller: passwordController,
                decoration: const InputDecoration(labelText: 'Password (min. 6 characters)'),
              obscureText: true,
            ),
          ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              if (nameController.text.trim().isEmpty) {
                 ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please enter your name.')));
                return;
              }
               if (emailController.text.trim().isEmpty) {
                 ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please enter your email.')));
                return;
              }
              if (passwordController.text.length < 6) {
                 ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Password must be at least 6 characters.')));
                return;
              }

              try {
                final UserCredential userCredential = 
                    await FirebaseAuth.instance.createUserWithEmailAndPassword(
                  email: emailController.text.trim(),
                  password: passwordController.text,
                );

                await userCredential.user?.updateDisplayName(nameController.text.trim());

                if (userCredential.user != null) {
                  await FirebaseFirestore.instance
                      .collection('users')
                      .doc(userCredential.user!.uid)
                      .set({
                    'email': userCredential.user!.email,
                    'displayName': nameController.text.trim(),
                    // photoURL will be null initially for email sign-up
                    'createdAt': FieldValue.serverTimestamp(),
                    'lastSignIn': FieldValue.serverTimestamp(),
                  });

                  ProviderScope.containerOf(context)
                      .read(userProvider.notifier)
                      .state = userCredential.user;
                }

                if (context.mounted) {
                  Navigator.pop(context); // Close dialog
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Account created successfully!')),
                  );
                }
              } on FirebaseAuthException catch (e) {
                 if (context.mounted) {
                  String message = 'An error occurred during sign up.';
                  if (e.code == 'weak-password') {
                    message = 'The password provided is too weak.';
                  } else if (e.code == 'email-already-in-use') {
                    message = 'The account already exists for that email.';
                  } else if (e.code == 'invalid-email') {
                    message = 'The email address is not valid.';
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(message)),
                  );
                }
              }
              catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: ${e.toString()}')),
                  );
                }
              }
            },
            child: const Text('Sign Up'),
          ),
        ],
      ),
    );
  }

  static Future<void> signOut(BuildContext context) async {
    try {
      await GoogleSignIn().signOut();
      await FirebaseAuth.instance.signOut();
      ProviderScope.containerOf(context).read(userProvider.notifier).state = null;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error signing out: ${e.toString()}')),
        );
      }
    }
  }
}


// AuthStateListener (should be fine as is)
class AuthStateListener extends ConsumerStatefulWidget {
  final Widget child;

  const AuthStateListener({super.key, required this.child});

  @override
  ConsumerState<AuthStateListener> createState() => _AuthStateListenerState();
}

class _AuthStateListenerState extends ConsumerState<AuthStateListener> {
  @override
  void initState() {
    super.initState();
    FirebaseAuth.instance.authStateChanges().listen((User? user) {
      if (mounted) { // Check if the widget is still in the tree
         ref.read(userProvider.notifier).state = user;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

// HomePage is not strictly necessary if AuthWrapper is the home
// but if you use it, it's fine.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProvider);

    if (user == null) {
      return const LoginScreen();
    }
    return const MainScreen();
  }
}