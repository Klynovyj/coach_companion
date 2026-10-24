/// Supabase-Zugang (anon „public" Key – kein Geheimnis; der Zugriff wird
/// serverseitig über Row-Level-Security geregelt, siehe supabase/schema.sql).
class SupabaseConfig {
  static const String url = 'https://ujrpsqfekmmjxypsdyza.supabase.co';
  static const String anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVqcnBzcWZla21tanh5cHNkeXphIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI4MjQwNDIsImV4cCI6MjEwODQwMDA0Mn0.37Ht9fqrnmIqS23qNNM81zRr-zPFc8K6pjiUMmUmvFg';

  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
}
