import 'package:google_maps_flutter/google_maps_flutter.dart';

class SelectedPlace {
  final LatLng position;
  final String address;
  final String? name;
  final String? placeId;

  SelectedPlace({
    required this.position,
    required this.address,
    this.name,
    this.placeId,
  });

  @override
  String toString() {
    if (address.isNotEmpty) {
      return address;
    }
    return 'Lat: ${position.latitude.toStringAsFixed(5)}, Lng: ${position.longitude.toStringAsFixed(5)}';
  }
} 