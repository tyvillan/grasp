import Foundation
import GRASPCore

/// The Supabase project GRASP syncs through -- the same one the Mac and
/// iPhone apps name in their Info.plist (GRASPSupabaseURL,
/// GRASPSupabaseAnonKey). Keep the two in step. The anon key is public by
/// design: row-level security keeps each account's rows its own.
enum SupabaseSettings {
    static let project = SupabaseProject(
        url: URL(string: "https://bchmnuizhxtofmbbuqwu.supabase.co")!,
        anonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJjaG1udWl6aHh0b2ZtYmJ1cXd1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAxNzI5NDIsImV4cCI6MjEwNTc0ODk0Mn0.G4rcUGsb0Nzpa_rGh-GOllKscqONnosVHfkha-kRAps"
    )
}
