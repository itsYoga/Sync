import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:location/location.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/selected_place.dart';

class MapScreen extends StatefulWidget {
  final SelectedPlace? initialPlace;
  const MapScreen({super.key, this.initialPlace});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? _mapController;
  Location _location = Location();
  LocationData? _currentLocation;
  SelectedPlace? _selectedPlace;
  Set<Marker> _markers = {};
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  List<Map<String, dynamic>> _searchResults = [];
  bool _isLoading = false;
  bool _initializedFromInitialPlace = false;

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    try {
      if (widget.initialPlace != null && !_initializedFromInitialPlace) {
        setState(() {
          _selectedPlace = widget.initialPlace;
          _markers = {
            Marker(
              markerId: const MarkerId('selected_location'),
              position: widget.initialPlace!.position,
              infoWindow: InfoWindow(title: 'Selected Location'),
            ),
          };
          _initializedFromInitialPlace = true;
        });
      } else {
      final locationData = await _location.getLocation();
      setState(() {
        _currentLocation = locationData;
      });
      }
    } catch (e) {
      debugPrint('Error getting location: $e');
    }
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    if (widget.initialPlace != null && !_initializedFromInitialPlace) {
      _updateMapLocation(widget.initialPlace!.position);
      setState(() {
        _initializedFromInitialPlace = true;
      });
    }
  }

  Future<void> _searchPlaces(String query) async {
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _isSearching = true;
    });
    try {
      final apiKey = dotenv.env['GOOGLE_MAPS_API_KEY'];
      final response = await http.get(
        Uri.parse(
          'https://maps.googleapis.com/maps/api/place/textsearch/json?query=$query&key=$apiKey',
        ),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _searchResults = List<Map<String, dynamic>>.from(data['results']);
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error searching places: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _updateMapLocation(LatLng position) {
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: position, zoom: 15),
      ),
    );
  }

  void _selectPlace(LatLng position, {String? address}) {
    setState(() {
      _selectedPlace = SelectedPlace(
        position: position,
        address: address ?? 'Lat: ${position.latitude.toStringAsFixed(5)}, Lng: ${position.longitude.toStringAsFixed(5)}',
      );
      _markers = {
        Marker(
          markerId: const MarkerId('selected_location'),
          position: position,
          infoWindow: InfoWindow(title: 'Selected Location'),
        ),
      };
    });
    _updateMapLocation(position);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Select Location', style: GoogleFonts.lato()),
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location),
            onPressed: () {
              if (_currentLocation != null) {
                _updateMapLocation(LatLng(
                  _currentLocation!.latitude!,
                  _currentLocation!.longitude!,
                ));
              }
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          _currentLocation == null
          ? const Center(child: CircularProgressIndicator())
          : GoogleMap(
              onMapCreated: _onMapCreated,
              initialCameraPosition: CameraPosition(
                    target: widget.initialPlace?.position ?? LatLng(
                  _currentLocation!.latitude!,
                  _currentLocation!.longitude!,
                ),
                zoom: 15,
              ),
              myLocationEnabled: true,
              myLocationButtonEnabled: true,
              markers: _markers,
              onTap: (LatLng position) {
                    _selectPlace(position);
                  },
                ),
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search places...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              _searchPlaces('');
                            },
                          )
                        : null,
                    border: InputBorder.none,
                  ),
                  onChanged: _searchPlaces,
                ),
              ),
            ),
          ),
          if (_isSearching)
            Container(
              color: Colors.white,
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: _searchResults.length,
                      itemBuilder: (context, index) {
                        final place = _searchResults[index];
                        final lat = place['geometry']['location']['lat'];
                        final lng = place['geometry']['location']['lng'];
                        final address = place['formatted_address'] ?? place['name'];
                        return ListTile(
                          leading: const Icon(Icons.place),
                          title: Text(place['name'] ?? ''),
                          subtitle: Text(address ?? ''),
                          onTap: () {
                            _searchController.text = address ?? '';
                setState(() {
                              _isSearching = false;
                            });
                            _selectPlace(LatLng(lat, lng), address: address);
                          },
                        );
                      },
                      ),
                    ),
        ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (_selectedPlace != null) {
            Navigator.pop(context, _selectedPlace);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Please select a location on the map')),
            );
          }
        },
        child: const Icon(Icons.check),
      ),
    );
  }
} 