// SAMPLE district data (generated from Smart-Attendance-SAMPLE-Data.xlsx).
// Made-up panchayats, habitations, streets and people for demonstrations.
// Replace with official data before real use. Do not edit by hand.

class SampleStreet {
  const SampleStreet(this.name, this.start, this.end, this.zones);
  final String name;
  final List<double> start;
  final List<double> end;
  final int zones;
}

class SampleHabitation {
  const SampleHabitation(this.name, this.streets);
  final String name;
  final List<SampleStreet> streets;
}

class SamplePanchayat {
  const SamplePanchayat(this.name, this.ta, this.zone, this.habitations);
  final String name;
  final String ta;
  final String zone;
  final List<SampleHabitation> habitations;
}

class SampleStaff {
  const SampleStaff(this.name, this.email, this.designation, this.panchayat, this.habitation, this.area);
  final String name;
  final String email;
  final String designation;
  final String panchayat;
  final String habitation;
  /// 'habitation' | 'panchayat' | 'zone:Zone A' | 'block' | 'district'
  final String area;
}

const sampleBlockName = 'Thirukazhukundram';
const sampleBlockTa = 'திருக்கழுக்குன்றம்';
const sampleZones = ['Zone A', 'Zone B'];

const samplePanchayats = <SamplePanchayat>[
  SamplePanchayat('Sample Pudupakkam', 'மாதிரி புதுப்பாக்கம்', 'Zone A', [
    SampleHabitation('Pudupakkam Colony', [
      SampleStreet('Sri Ram Nagar', [12.605662, 80.055341], [12.607467, 80.056172], 6),
      SampleStreet('Gandhi Street', [12.606471, 80.055894], [12.606746, 80.058274], 8),
    ]),
    SampleHabitation('Pudupakkam Main Village', [
      SampleStreet('Anna Nagar', [12.608, 80.057], [12.609357, 80.058475], 8),
      SampleStreet('Periyar Street', [12.608809, 80.057553], [12.609833, 80.055818], 6),
    ]),
    SampleHabitation('Pudupakkam New Nagar', [
      SampleStreet('Kamarajar Salai', [12.610338, 80.058659], [12.612259, 80.058172], 8),
      SampleStreet('Bharathi Street', [12.611148, 80.059212], [12.611295, 80.05719], 6),
    ]),
  ]),
  SamplePanchayat('Sample Nallur', 'மாதிரி நல்லூர்', 'Zone A', [
    SampleHabitation('Nallur Colony', [
      SampleStreet('Nehru Street', [12.614662, 80.068341], [12.616508, 80.069812], 7),
      SampleStreet('Temple Street', [12.615471, 80.068894], [12.617401, 80.068446], 7),
    ]),
    SampleHabitation('Nallur Main Village', [
      SampleStreet('Pillaiyar Koil Street', [12.617, 80.07], [12.619153, 80.070935], 6),
      SampleStreet('School Street', [12.617809, 80.070553], [12.619651, 80.069812], 8),
    ]),
    SampleHabitation('Nallur New Nagar', [
      SampleStreet('Market Road', [12.619338, 80.071659], [12.621308, 80.069262], 8),
      SampleStreet('Lake View Street', [12.620148, 80.072212], [12.622921, 80.073532], 7),
    ]),
  ]),
  SamplePanchayat('Sample Vadakupattu', 'மாதிரி வடக்குப்பட்டு', 'Zone A', [
    SampleHabitation('Vadakupattu Colony', [
      SampleStreet('Sri Ram Nagar', [12.599162, 80.068841], [12.599756, 80.071158], 8),
      SampleStreet('Gandhi Street', [12.599971, 80.069394], [12.60114, 80.066499], 8),
    ]),
    SampleHabitation('Vadakupattu Main Village', [
      SampleStreet('Anna Nagar', [12.6015, 80.0705], [12.602217, 80.072389], 8),
      SampleStreet('Periyar Street', [12.602309, 80.071053], [12.603925, 80.069321], 7),
    ]),
    SampleHabitation('Vadakupattu New Nagar', [
      SampleStreet('Kamarajar Salai', [12.603838, 80.072159], [12.604214, 80.075268], 6),
      SampleStreet('Bharathi Street', [12.604648, 80.072712], [12.607012, 80.074043], 8),
    ]),
  ]),
  SamplePanchayat('Sample Echur', 'மாதிரி எச்சூர்', 'Zone B', [
    SampleHabitation('Echur Colony', [
      SampleStreet('Nehru Street', [12.621162, 80.050841], [12.621817, 80.053902], 6),
      SampleStreet('Temple Street', [12.621971, 80.051394], [12.62466, 80.051619], 6),
    ]),
    SampleHabitation('Echur Main Village', [
      SampleStreet('Pillaiyar Koil Street', [12.6235, 80.0525], [12.625915, 80.051267], 8),
      SampleStreet('School Street', [12.624309, 80.053053], [12.626406, 80.051313], 8),
    ]),
    SampleHabitation('Echur New Nagar', [
      SampleStreet('Market Road', [12.625838, 80.054159], [12.628586, 80.055533], 6),
      SampleStreet('Lake View Street', [12.626648, 80.054712], [12.627211, 80.057792], 8),
    ]),
  ]),
  SamplePanchayat('Sample Mamallan Nagar', 'மாதிரி மாமல்லன் நகர்', 'Zone B', [
    SampleHabitation('Mamallan Nagar Colony', [
      SampleStreet('Sri Ram Nagar', [12.592662, 80.058341], [12.594881, 80.059097], 8),
      SampleStreet('Gandhi Street', [12.593471, 80.058894], [12.594459, 80.060651], 8),
    ]),
    SampleHabitation('Mamallan Nagar Main Village', [
      SampleStreet('Anna Nagar', [12.595, 80.06], [12.595966, 80.057419], 8),
      SampleStreet('Periyar Street', [12.595809, 80.060553], [12.59796, 80.058883], 8),
    ]),
    SampleHabitation('Mamallan Nagar New Nagar', [
      SampleStreet('Kamarajar Salai', [12.597338, 80.061659], [12.598406, 80.06379], 7),
      SampleStreet('Bharathi Street', [12.598148, 80.062212], [12.599705, 80.063999], 7),
    ]),
  ]),
  SamplePanchayat('Sample Karumbakkam', 'மாதிரி கரும்பாக்கம்', 'Zone B', [
    SampleHabitation('Karumbakkam Colony', [
      SampleStreet('Nehru Street', [12.609662, 80.080341], [12.611209, 80.077639], 7),
      SampleStreet('Temple Street', [12.610471, 80.080894], [12.61256, 80.082643], 7),
    ]),
    SampleHabitation('Karumbakkam Main Village', [
      SampleStreet('Pillaiyar Koil Street', [12.612, 80.082], [12.614539, 80.081065], 8),
      SampleStreet('School Street', [12.612809, 80.082553], [12.614741, 80.081203], 6),
    ]),
    SampleHabitation('Karumbakkam New Nagar', [
      SampleStreet('Market Road', [12.614338, 80.083659], [12.61724, 80.084645], 8),
      SampleStreet('Lake View Street', [12.615148, 80.084212], [12.617123, 80.084329], 8),
    ]),
  ]),
];

const sampleStaff = <SampleStaff>[
  SampleStaff('Lakshmi M', 'sample.tk001@example.com', 'Thoomai Kavalar', 'Sample Pudupakkam', 'Pudupakkam Colony', 'habitation'),
  SampleStaff('Murugan N', 'sample.tk002@example.com', 'Thoomai Kavalar', 'Sample Pudupakkam', 'Pudupakkam Main Village', 'habitation'),
  SampleStaff('Senthil R', 'sample.tk003@example.com', 'Thoomai Kavalar', 'Sample Pudupakkam', 'Pudupakkam New Nagar', 'habitation'),
  SampleStaff('Revathi G', 'sample.oht004@example.com', 'OHT Operator', 'Sample Pudupakkam', 'Pudupakkam Colony', 'panchayat'),
  SampleStaff('Murugan M', 'sample.mnp005@example.com', 'Makkal Nala Paniyalar (MNP)', 'Sample Pudupakkam', '', 'panchayat'),
  SampleStaff('Karthik V', 'sample.vps006@example.com', 'Village Panchayat Secretary', 'Sample Pudupakkam', '', 'panchayat'),
  SampleStaff('Saravanan M', 'sample.tk007@example.com', 'Thoomai Kavalar', 'Sample Nallur', 'Nallur Colony', 'habitation'),
  SampleStaff('Revathi P', 'sample.tk008@example.com', 'Thoomai Kavalar', 'Sample Nallur', 'Nallur Main Village', 'habitation'),
  SampleStaff('Devi G', 'sample.tk009@example.com', 'Thoomai Kavalar', 'Sample Nallur', 'Nallur New Nagar', 'habitation'),
  SampleStaff('Raja S', 'sample.oht010@example.com', 'OHT Operator', 'Sample Nallur', 'Nallur Colony', 'panchayat'),
  SampleStaff('Bala T', 'sample.mnp011@example.com', 'Makkal Nala Paniyalar (MNP)', 'Sample Nallur', '', 'panchayat'),
  SampleStaff('Jaya N', 'sample.vps012@example.com', 'Village Panchayat Secretary', 'Sample Nallur', '', 'panchayat'),
  SampleStaff('Karthik R', 'sample.tk013@example.com', 'Thoomai Kavalar', 'Sample Vadakupattu', 'Vadakupattu Colony', 'habitation'),
  SampleStaff('Velu V', 'sample.tk014@example.com', 'Thoomai Kavalar', 'Sample Vadakupattu', 'Vadakupattu Main Village', 'habitation'),
  SampleStaff('Priya A', 'sample.tk015@example.com', 'Thoomai Kavalar', 'Sample Vadakupattu', 'Vadakupattu New Nagar', 'habitation'),
  SampleStaff('Murugan R', 'sample.oht016@example.com', 'OHT Operator', 'Sample Vadakupattu', 'Vadakupattu Colony', 'panchayat'),
  SampleStaff('Karthik A', 'sample.mnp017@example.com', 'Makkal Nala Paniyalar (MNP)', 'Sample Vadakupattu', '', 'panchayat'),
  SampleStaff('Karthik G', 'sample.vps018@example.com', 'Village Panchayat Secretary', 'Sample Vadakupattu', '', 'panchayat'),
  SampleStaff('Saravanan P', 'sample.tk019@example.com', 'Thoomai Kavalar', 'Sample Echur', 'Echur Colony', 'habitation'),
  SampleStaff('Saravanan G', 'sample.tk020@example.com', 'Thoomai Kavalar', 'Sample Echur', 'Echur Main Village', 'habitation'),
  SampleStaff('Selvi M', 'sample.tk021@example.com', 'Thoomai Kavalar', 'Sample Echur', 'Echur New Nagar', 'habitation'),
  SampleStaff('Vasuki S', 'sample.oht022@example.com', 'OHT Operator', 'Sample Echur', 'Echur Colony', 'panchayat'),
  SampleStaff('Priya M', 'sample.mnp023@example.com', 'Makkal Nala Paniyalar (MNP)', 'Sample Echur', '', 'panchayat'),
  SampleStaff('Prakash K', 'sample.vps024@example.com', 'Village Panchayat Secretary', 'Sample Echur', '', 'panchayat'),
  SampleStaff('Ravi S', 'sample.tk025@example.com', 'Thoomai Kavalar', 'Sample Mamallan Nagar', 'Mamallan Nagar Colony', 'habitation'),
  SampleStaff('Kumar A', 'sample.tk026@example.com', 'Thoomai Kavalar', 'Sample Mamallan Nagar', 'Mamallan Nagar Main Village', 'habitation'),
  SampleStaff('Selvi P', 'sample.tk027@example.com', 'Thoomai Kavalar', 'Sample Mamallan Nagar', 'Mamallan Nagar New Nagar', 'habitation'),
  SampleStaff('Bala K', 'sample.oht028@example.com', 'OHT Operator', 'Sample Mamallan Nagar', 'Mamallan Nagar Colony', 'panchayat'),
  SampleStaff('Ravi R', 'sample.mnp029@example.com', 'Makkal Nala Paniyalar (MNP)', 'Sample Mamallan Nagar', '', 'panchayat'),
  SampleStaff('Bala A', 'sample.vps030@example.com', 'Village Panchayat Secretary', 'Sample Mamallan Nagar', '', 'panchayat'),
  SampleStaff('Malar M', 'sample.tk031@example.com', 'Thoomai Kavalar', 'Sample Karumbakkam', 'Karumbakkam Colony', 'habitation'),
  SampleStaff('Karthik P', 'sample.tk032@example.com', 'Thoomai Kavalar', 'Sample Karumbakkam', 'Karumbakkam Main Village', 'habitation'),
  SampleStaff('Murugan S', 'sample.tk033@example.com', 'Thoomai Kavalar', 'Sample Karumbakkam', 'Karumbakkam New Nagar', 'habitation'),
  SampleStaff('Devi P', 'sample.oht034@example.com', 'OHT Operator', 'Sample Karumbakkam', 'Karumbakkam Colony', 'panchayat'),
  SampleStaff('Arul A', 'sample.mnp035@example.com', 'Makkal Nala Paniyalar (MNP)', 'Sample Karumbakkam', '', 'panchayat'),
  SampleStaff('Senthil S', 'sample.vps036@example.com', 'Village Panchayat Secretary', 'Sample Karumbakkam', '', 'panchayat'),
  SampleStaff('Selvi R', 'sample.zdbdo037@example.com', 'Zonal Deputy BDO', '', '', 'zone:Zone A'),
  SampleStaff('Velu A', 'sample.zdbdo038@example.com', 'Zonal Deputy BDO', '', '', 'zone:Zone B'),
  SampleStaff('Lakshmi A', 'sample.dbdop039@example.com', 'Deputy BDO (Panchayats)', '', '', 'block'),
  SampleStaff('Selvi K', 'sample.dbdor040@example.com', 'Deputy BDO (Regular)', '', '', 'block'),
  SampleStaff('Raja A', 'sample.bdovp041@example.com', 'BDO (Village Panchayats)', '', '', 'block'),
  SampleStaff('Uma A', 'sample.bdobp042@example.com', 'BDO (Block Panchayat)', '', '', 'block'),
  SampleStaff('Revathi T', 'sample.dm043@example.com', 'District monitoring', '', '', 'district'),
];
