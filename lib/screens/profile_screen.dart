import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'dart:convert';
import 'dart:io';
import '../main.dart'; // To access userProvider and AuthService

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final TextEditingController _displayNameController = TextEditingController();
  bool _isEditingName = false;
  bool _isLoading = false;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _updateControllerFromUser();
  }

  @override
  void didUpdateWidget(ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateControllerFromUser();
  }

  void _updateControllerFromUser() {
    final user = ref.read(userProvider);
    if (!_isEditingName && user != null) {
      _displayNameController.text = user.displayName ?? '';
    }
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _updateDisplayName() async {
    final user = FirebaseAuth.instance.currentUser;
    final newName = _displayNameController.text.trim();

    if (user == null || newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Display name cannot be empty.')),
      );
      return;
    }

    if (newName == user.displayName) {
      setState(() {
        _isEditingName = false;
      });
      return; // No changes to save
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // Update in Firestore
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({'displayName': newName});

      // Update in FirebaseAuth
      await user.updateDisplayName(newName);
      // Refresh the user object to reflect changes immediately in UI if needed,
      // though authStateChanges should pick it up.
      await user.reload();
      final updatedUser = FirebaseAuth.instance.currentUser;


      // Update the userProvider state. This will trigger UI rebuilds where userProvider is watched.
      ref.read(userProvider.notifier).state = updatedUser;


      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Display name updated successfully!')),
        );
        setState(() {
          _isEditingName = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating display name: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showEditDisplayNameDialog() {
    final user = ref.read(userProvider);
    _displayNameController.text = user?.displayName ?? ''; // Reset before showing dialog

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit Display Name'),
          content: TextField(
            controller: _displayNameController,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Enter new display name'),
            textCapitalization: TextCapitalization.words,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog first
                _updateDisplayName();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showChangePhotoURLDialog() {
    final user = ref.read(userProvider);
    final TextEditingController urlController = TextEditingController(text: user?.photoURL ?? '');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Change Profile Picture URL'),
          content: TextField(
            controller: urlController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Image URL',
              hintText: 'https://example.com/image.png',
            ),
            keyboardType: TextInputType.url,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
                _updatePhotoURL(urlController.text.trim());
              },
              child: const Text('Save URL'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _updatePhotoURL(String newPhotoURL) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Basic URL validation
    if (newPhotoURL.isNotEmpty && !Uri.parse(newPhotoURL).isAbsolute) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a valid image URL.')),
        );
      }
      return;
    }

    if (newPhotoURL == user.photoURL) {
      return; // No change
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // Update in Firestore
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({'photoURL': newPhotoURL.isNotEmpty ? newPhotoURL : null});

      // Update in FirebaseAuth
      await user.updatePhotoURL(newPhotoURL.isNotEmpty ? newPhotoURL : null);
      await user.reload();

      final updatedUser = FirebaseAuth.instance.currentUser;
      ref.read(userProvider.notifier).state = updatedUser;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile picture URL updated!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating photo URL: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _pickAndSaveImage() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 70,
      );

      if (image == null) return;

      setState(() {
        _isLoading = true;
      });

      // Compress the image
      final File imageFile = File(image.path);
      final List<int>? compressedBytes = await FlutterImageCompress.compressWithFile(
        imageFile.absolute.path,
        minWidth: 300,
        minHeight: 300,
        quality: 70,
      );

      if (compressedBytes == null) {
        throw Exception('Image compression failed');
      }

      // Convert to Base64
      final String base64Image = base64Encode(compressedBytes);

      // Check size (Firestore document limit is ~1MB)
      if (base64Image.length > 700000) {
        throw Exception('Image is too large after compression');
      }

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // Update in Firestore
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({
        'photoBase64': base64Image,
        'photoURL': null, // Clear the old URL
      });

      // Update in FirebaseAuth
      await user.updatePhotoURL(null); // Clear the old URL
      await user.reload();

      final updatedUser = FirebaseAuth.instance.currentUser;
      ref.read(userProvider.notifier).state = updatedUser;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile picture updated successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating profile picture: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showImagePickerOptions() {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from Gallery'),
                onTap: () {
                  Navigator.pop(context);
                  _pickAndSaveImage();
                },
              ),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('Enter Image URL'),
                onTap: () {
                  Navigator.pop(context);
                  _showChangePhotoURLDialog();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    final theme = Theme.of(context);
    final photoUrl = user?.photoURL;

    if (user == null) {
      return const Center(child: CircularProgressIndicator());
    }
    
    if (!_isEditingName && _displayNameController.text != (user.displayName ?? '')) {
        _displayNameController.text = user.displayName ?? '';
    }

    return Scaffold(
      body: Container(
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 20),
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  FutureBuilder<DocumentSnapshot>(
                    future: FirebaseFirestore.instance
                        .collection('users')
                        .doc(user.uid)
                        .get(),
                    builder: (context, snapshot) {
                      if (snapshot.hasData && snapshot.data != null) {
                        final userData = snapshot.data!.data() as Map<String, dynamic>?;
                        final base64Image = userData?['photoBase64'] as String?;
                        
                        if (base64Image != null && base64Image.isNotEmpty) {
                          return CircleAvatar(
                            radius: 60,
                            backgroundColor: theme.colorScheme.primaryContainer,
                            backgroundImage: MemoryImage(base64Decode(base64Image)),
                          );
                        }
                      }
                      
                      // Fallback to URL or initials
                      return CircleAvatar(
                        radius: 60,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        backgroundImage: (photoUrl != null && photoUrl.isNotEmpty)
                            ? NetworkImage(photoUrl)
                            : null,
                        child: (photoUrl == null || photoUrl.isEmpty)
                            ? Text(
                                user.displayName?.substring(0, 1).toUpperCase() ??
                                    user.email?.substring(0, 1).toUpperCase() ??
                                    'U',
                                style: theme.textTheme.displaySmall?.copyWith(
                                    color: theme.colorScheme.onPrimaryContainer,
                                    fontWeight: FontWeight.bold
                                ),
                              )
                            : null,
                      );
                    },
                  ),
                  Material(
                    color: theme.colorScheme.secondaryContainer.withOpacity(0.8),
                    shape: const CircleBorder(),
                    elevation: 2,
                    child: InkWell(
                      onTap: _showImagePickerOptions,
                      customBorder: const CircleBorder(),
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Icon(
                          Icons.edit,
                          size: 20,
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Display Name',
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          IconButton(
                            icon: Icon(Icons.edit_outlined, color: theme.colorScheme.primary, size: 20),
                            onPressed: _showEditDisplayNameDialog,
                            tooltip: 'Edit Display Name',
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        user.displayName ?? 'Not set',
                        style: theme.textTheme.bodyLarge?.copyWith(fontSize: 18),
                      ),
                      const Divider(height: 32),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                           Text(
                            'Email',
                             style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                          ),
                           // Email is usually not editable
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        user.email ?? 'No email associated',
                        style: theme.textTheme.bodyLarge?.copyWith(fontSize: 18),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
              const Divider(),
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20.0),
                  child: CircularProgressIndicator(),
                ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.logout_outlined),
                label: const Text('Sign Out'),
                onPressed: () => AuthService.signOut(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.errorContainer,
                  foregroundColor: theme.colorScheme.onErrorContainer,
                  minimumSize: const Size(double.infinity, 50),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 16)
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'User ID: ${user.uid}',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.5)),
              )
            ],
          ),
        ),
      ),
    );
  }
}
