/// The eight roles of the system (Phase 1, section 3).
///
/// The [key] is stored in the database and never changes. The title shown to
/// people comes from configuration (`hierarchyLevels/{key}`), because each
/// district names its officers differently; [defaultTitle] is used until an
/// administrator sets one.
enum Role {
  collector('collector', 'District Collector'),
  officer('officer', 'AD / higher-level officer'),
  zonalSecretary('zonal_secretary', 'Zonal Secretary'),
  supervisor('supervisor', 'Supervisor'),
  orgAdmin('org_admin', 'Organisation administrator'),
  worker('worker', 'Field worker'),
  auditor('auditor', 'Auditor'),
  sysAdmin('sys_admin', 'System administrator');

  const Role(this.key, this.defaultTitle);
  final String key;
  final String defaultTitle;

  static Role? fromKey(String? key) {
    for (final r in Role.values) {
      if (r.key == key) return r;
    }
    return null;
  }

  /// Officers manage or monitor other people; everyone else uses the worker app.
  bool get isFieldWorker => this == Role.worker;

  /// Order used to pick the starting role when one person holds several
  /// (for example a supervisor who is also an auditor). Lower comes first.
  int get priority => switch (this) {
        Role.collector => 0,
        Role.officer => 1,
        Role.zonalSecretary => 2,
        Role.supervisor => 3,
        Role.orgAdmin => 4,
        Role.auditor => 5,
        Role.sysAdmin => 6,
        Role.worker => 7,
      };
}
