import 'package:supabase_flutter/supabase_flutter.dart';

const String supabaseUrl = 'https://cupiklbeuxdjwjdkojfw.supabase.co';

const String supabasePublishableKey = 'sb_publishable_oa2PLogsXsMEGlxQ2tBLKA_1L0AffYV';

final SupabaseClient supabase = SupabaseClient(
  supabaseUrl,
  supabasePublishableKey,
);
