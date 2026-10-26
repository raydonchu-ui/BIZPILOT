// Towns of Cameroon that buyers can choose. A seller's city is matched against these names with
// accents and punctuation ignored (app.city_key in the database), so "Yaounde" finds "Yaoundé".
export const CAMEROON_CITIES = [
  'Abong-Mbang', 'Akonolinga', 'Ayos', 'Bafang', 'Bafia', 'Bafoussam', 'Bafut', 'Bamenda', 'Bangangté', 'Batouri',
  'Bélabo', 'Bertoua', 'Buea', 'Dschang', 'Douala', 'Ebolowa', 'Edéa', 'Eseka', 'Foumban', 'Foumbot', 'Garoua',
  'Garoua-Boulaï', 'Guider', 'Kousséri', 'Kribi', 'Kumba', 'Kumbo', 'Limbé', 'Loum', 'Mamfe', 'Mbalmayo', 'Mbanga',
  'Mbouda', 'Meiganga', 'Melong', 'Mokolo', 'Muyuka', 'Ndop', 'Ngaoundal', 'Ngaoundéré', 'Nkambé', 'Nkongsamba',
  'Penja', 'Sangmélima', 'Tibati', 'Tiko', 'Victoria', 'Wum', 'Yagoua', 'Yaoundé', 'Yokadouma',
] as const;

/** Same normalisation as app.city_key: lower case, accents and punctuation removed. */
export function cityKey(name: string | null | undefined): string {
  return (name ?? '')
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/[^a-z0-9]/g, '');
}
