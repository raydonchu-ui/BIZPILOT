// Suggested categories per business type (owners pick what they need; nothing is forced) and the
// optional, category-specific product details ("attributes") shown on the product form.

export const BUSINESS_TYPES = [
  'grocery', 'supermarket', 'drinks', 'fashion', 'footwear', 'electronics', 'hair_beauty', 'cosmetics', 'furniture',
  'hardware', 'automotive', 'sports', 'toys', 'books', 'stationery', 'jewelry', 'pets', 'agriculture', 'home_goods',
  'gifts', 'general', 'other',
] as const;
export type BusinessType = (typeof BUSINESS_TYPES)[number];

// The 8 types a database without the October 2026 upgrade accepts, and the closest one for each new type.
export const LEGACY_TYPES = ['grocery', 'general', 'drinks', 'hardware', 'electronics', 'fashion', 'cosmetics', 'other'];
export function legacyType(type: string): string {
  if (LEGACY_TYPES.includes(type)) return type;
  return ({ supermarket: 'grocery', agriculture: 'grocery', footwear: 'fashion', jewelry: 'fashion', hair_beauty: 'cosmetics', automotive: 'hardware', furniture: 'general' } as Record<string, string>)[type] ?? 'general';
}

export type AttributeSet = 'clothing' | 'footwear' | 'electronics' | 'hair' | 'beauty' | 'grocery' | 'furniture'
  | 'jewelry' | 'automotive' | 'books' | 'general';

export const DEFAULT_ATTRIBUTE_SET: Record<BusinessType, AttributeSet> = {
  grocery: 'grocery', supermarket: 'grocery', drinks: 'grocery', fashion: 'clothing', footwear: 'footwear',
  electronics: 'electronics', hair_beauty: 'hair', cosmetics: 'beauty', furniture: 'furniture', hardware: 'general',
  automotive: 'automotive', sports: 'general', toys: 'general', books: 'books', stationery: 'general', jewelry: 'jewelry',
  pets: 'general', agriculture: 'grocery', home_goods: 'general', gifts: 'general', general: 'general', other: 'general',
};

// ---------------------------------------------------------------------------
// Category templates. Compact notation: 'English|Français; English|Français; …'
// ---------------------------------------------------------------------------
interface Top { en: string; fr: string; set?: AttributeSet; sub?: string }
const T = (en: string, fr: string, sub?: string, set?: AttributeSet): Top => ({ en, fr, sub, set });

const FOOTWEAR_SUB = 'Shoes|Chaussures; Sneakers|Baskets; Boots|Bottes; Sandals|Sandales; Slippers|Pantoufles';
const GROCERY: Top[] = [
  T('Food staples', 'Produits de base', 'Rice|Riz; Flour|Farine; Pasta & noodles|Pâtes & nouilles; Sugar & salt|Sucre & sel; Cooking oil|Huile; Beans & grains|Haricots & céréales; Spices & seasoning|Épices & assaisonnements'),
  T('Beverages', 'Boissons', 'Water|Eau; Soft drinks|Boissons gazeuses; Juice|Jus; Tea & coffee|Thé & café; Milk drinks|Boissons lactées'),
  T('Packaged food', 'Produits emballés', 'Canned food|Conserves; Breakfast cereals|Céréales du petit-déjeuner; Snacks & biscuits|Snacks & biscuits; Sweets & chocolate|Bonbons & chocolat'),
  T('Dairy & eggs', 'Produits laitiers & œufs', 'Milk|Lait; Yoghurt|Yaourt; Cheese|Fromage; Butter & margarine|Beurre & margarine; Eggs|Œufs'),
  T('Fresh produce', 'Produits frais', 'Fruits|Fruits; Vegetables|Légumes; Meat & fish|Viande & poisson; Bread & bakery|Pain & boulangerie'),
  T('Household', 'Entretien ménager', 'Detergent & soap|Détergent & savon; Cleaning products|Produits de nettoyage; Paper & tissues|Papier & mouchoirs; Insecticides|Insecticides'),
  T('Personal care', 'Hygiène', 'Body soap|Savon de toilette; Toothpaste|Dentifrice; Sanitary products|Produits hygiéniques; Baby care|Soins bébé'),
];

export const CATEGORY_TEMPLATES: Record<BusinessType, Top[]> = {
  grocery: GROCERY,
  supermarket: [...GROCERY,
    T('Frozen food', 'Surgelés', 'Frozen meat & fish|Viande & poisson surgelés; Ice cream|Glaces; Frozen vegetables|Légumes surgelés'),
    T('Home & kitchen', 'Maison & cuisine', 'Kitchenware|Ustensiles de cuisine; Plastic ware|Articles en plastique; Batteries & bulbs|Piles & ampoules', 'general')],
  drinks: [
    T('Beer', 'Bières'), T('Soft drinks', 'Boissons gazeuses'), T('Water', 'Eaux'), T('Juice', 'Jus'),
    T('Wine', 'Vins'), T('Spirits', 'Spiritueux'), T('Energy drinks', 'Boissons énergisantes'), T('Crates & empties', 'Casiers & emballages vides'),
  ],
  fashion: [
    T('Men', 'Hommes', 'T-shirts|T-shirts; Polo shirts|Polos; Long-sleeve shirts|Chemises manches longues; Short-sleeve shirts|Chemises manches courtes; Trousers|Pantalons; Jeans|Jeans; Shorts|Shorts; Cargo pants|Pantalons cargo; Joggers|Joggings; Hoodies|Sweats à capuche; Sweatshirts|Sweat-shirts; Jackets|Vestes; Coats|Manteaux; Suits|Costumes; Underwear|Sous-vêtements', 'clothing'),
    T('Women', 'Femmes', 'T-shirts|T-shirts; Blouses & tops|Blouses & hauts; Dresses|Robes; Skirts|Jupes; Trousers|Pantalons; Jeans|Jeans; Shorts|Shorts; Hoodies|Sweats à capuche; Sweatshirts|Sweat-shirts; Jackets|Vestes; Coats|Manteaux; Lingerie|Lingerie', 'clothing'),
    T('Kids', 'Enfants', 'T-shirts|T-shirts; Shirts|Chemises; Trousers|Pantalons; Shorts|Shorts; Dresses|Robes; School uniforms|Uniformes scolaires; Jackets|Vestes', 'clothing'),
    T('Baby', 'Bébé', 'Bodysuits|Bodies; Sleepsuits|Pyjamas; Sets|Ensembles; Hats & mittens|Bonnets & moufles', 'clothing'),
    T('Unisex', 'Unisexe', 'T-shirts|T-shirts; Hoodies|Sweats à capuche; Sweatshirts|Sweat-shirts; Joggers|Joggings; Jackets|Vestes', 'clothing'),
    T('Sportswear', 'Vêtements de sport', 'Jerseys|Maillots; Tracksuits|Survêtements; Shorts|Shorts; Leggings|Leggings', 'clothing'),
    T('Traditional clothing', 'Tenues traditionnelles', 'Kaba & ngondo|Kaba & ngondo; Boubou|Boubou; Wax & pagne|Wax & pagne; Agbada|Agbada; Toghu|Toghu', 'clothing'),
    T('Workwear', 'Tenues de travail', 'Uniforms|Uniformes; Overalls|Combinaisons; Safety wear|Équipements de sécurité', 'clothing'),
    T('Footwear', 'Chaussures', FOOTWEAR_SUB, 'footwear'),
    T('Accessories', 'Accessoires', 'Watches|Montres; Bags|Sacs; Belts|Ceintures; Jewelry|Bijoux; Caps & hats|Casquettes & chapeaux; Sunglasses|Lunettes de soleil; Scarves|Écharpes; Socks|Chaussettes', 'general'),
  ],
  footwear: [
    T('Men', 'Hommes', 'Sneakers|Baskets; Formal shoes|Chaussures de ville; Boots|Bottes; Sandals|Sandales; Slippers|Pantoufles', 'footwear'),
    T('Women', 'Femmes', 'Sneakers|Baskets; Heels|Talons; Flats|Ballerines; Boots|Bottes; Sandals|Sandales; Slippers|Pantoufles', 'footwear'),
    T('Kids', 'Enfants', 'Sneakers|Baskets; School shoes|Chaussures scolaires; Sandals|Sandales', 'footwear'),
    T('Sports shoes', 'Chaussures de sport', 'Football boots|Crampons; Running shoes|Chaussures de course; Basketball shoes|Chaussures de basket', 'footwear'),
    T('Shoe care & accessories', 'Entretien & accessoires', 'Polish|Cirage; Laces|Lacets; Insoles|Semelles', 'general'),
  ],
  electronics: [
    T('Phones', 'Téléphones', 'Smartphones|Smartphones; Feature phones|Téléphones simples; Refurbished phones|Téléphones reconditionnés'),
    T('Computers', 'Informatique', 'Laptops|Ordinateurs portables; Desktops|Ordinateurs de bureau; Monitors|Écrans; Printers|Imprimantes; Storage|Stockage'),
    T('Tablets', 'Tablettes'),
    T('TV & video', 'TV & vidéo', 'Televisions|Téléviseurs; Decoders|Décodeurs; Projectors|Projecteurs'),
    T('Audio', 'Audio', 'Headphones|Casques; Earbuds|Écouteurs; Speakers|Enceintes; Home theatre|Home cinéma'),
    T('Accessories', 'Accessoires', 'Chargers|Chargeurs; Cables|Câbles; Power banks|Batteries externes; Cases & covers|Coques & étuis; Screen protectors|Protections d’écran; Memory cards|Cartes mémoire'),
    T('Cameras', 'Appareils photo', 'Cameras|Appareils photo; Security cameras|Caméras de surveillance; Lenses & accessories|Objectifs & accessoires'),
    T('Gaming', 'Jeux vidéo', 'Consoles|Consoles; Games|Jeux; Controllers|Manettes'),
    T('Networking', 'Réseau', 'Routers|Routeurs; Modems|Modems; Wi-Fi extenders|Répéteurs Wi-Fi; Network cables|Câbles réseau'),
    T('Spare parts', 'Pièces détachées', 'Screens|Écrans; Batteries|Batteries; Charging ports|Connecteurs de charge; Boards|Cartes électroniques'),
    T('Appliances', 'Électroménager', 'Fridges|Réfrigérateurs; Fans|Ventilateurs; Irons|Fers à repasser; Blenders|Mixeurs', 'general'),
  ],
  hair_beauty: [
    T('Wigs', 'Perruques', 'Human hair wigs|Perruques en cheveux naturels; Synthetic wigs|Perruques synthétiques; Lace front wigs|Perruques lace front; Closure wigs|Perruques closure', 'hair'),
    T('Hair extensions', 'Extensions', 'Human hair|Cheveux naturels; Bundles|Tissages; Closures|Closures; Frontals|Frontals; Clip-ins|Extensions à clips; Braiding hair|Mèches à tresser; Crochet hair|Mèches crochet', 'hair'),
    T('Hair care', 'Soins capillaires', 'Shampoos|Shampooings; Conditioners|Après-shampooings; Hair oils|Huiles capillaires; Relaxers|Défrisants; Creams & hair food|Crèmes & nourrissants; Treatments|Soins', 'beauty'),
    T('Styling tools', 'Appareils de coiffure', 'Clippers|Tondeuses; Hair dryers|Sèche-cheveux; Straighteners|Lisseurs; Curlers|Boucleurs; Combs & brushes|Peignes & brosses', 'general'),
    T('Makeup', 'Maquillage', 'Foundation|Fond de teint; Powder|Poudre; Lipstick|Rouge à lèvres; Eye makeup|Maquillage des yeux; Brushes|Pinceaux', 'beauty'),
    T('Skincare', 'Soins de la peau', 'Cleansers|Nettoyants; Creams & lotions|Crèmes & laits; Serums|Sérums; Sunscreen|Écran solaire', 'beauty'),
    T('Perfumes', 'Parfums', 'Women’s perfume|Parfums femme; Men’s perfume|Parfums homme; Body mists|Brumes corporelles', 'beauty'),
    T('Nails', 'Ongles', 'Nail polish|Vernis; Artificial nails|Faux ongles; Nail tools|Accessoires ongles', 'beauty'),
    T('Salon supplies', 'Fournitures de salon', 'Capes & towels|Capes & serviettes; Chairs & equipment|Fauteuils & équipements; Disposables|Consommables', 'general'),
  ],
  cosmetics: [
    T('Skincare', 'Soins de la peau', 'Cleansers|Nettoyants; Creams & lotions|Crèmes & laits; Serums|Sérums; Sunscreen|Écran solaire'),
    T('Makeup', 'Maquillage', 'Foundation|Fond de teint; Powder|Poudre; Lipstick|Rouge à lèvres; Eye makeup|Maquillage des yeux'),
    T('Fragrances', 'Parfums', 'Women’s perfume|Parfums femme; Men’s perfume|Parfums homme; Body mists|Brumes corporelles'),
    T('Hair care', 'Soins capillaires', 'Shampoos|Shampooings; Conditioners|Après-shampooings; Hair oils|Huiles capillaires'),
    T('Body care', 'Soins du corps', 'Body lotions|Laits corporels; Shower gels|Gels douche; Deodorants|Déodorants'),
    T('Men’s grooming', 'Soins homme', 'Shaving|Rasage; Beard care|Soins de la barbe'),
  ],
  furniture: [
    T('Living room', 'Salon', 'Sofas|Canapés; Armchairs|Fauteuils; Coffee tables|Tables basses; TV stands|Meubles TV'),
    T('Bedroom', 'Chambre', 'Beds|Lits; Mattresses|Matelas; Wardrobes|Armoires; Dressers|Commodes'),
    T('Dining', 'Salle à manger', 'Dining tables|Tables à manger; Chairs|Chaises'),
    T('Office', 'Bureau', 'Desks|Bureaux; Office chairs|Chaises de bureau; Shelves|Étagères'),
    T('Outdoor', 'Extérieur', 'Garden furniture|Mobilier de jardin; Plastic chairs|Chaises en plastique'),
    T('Decor', 'Décoration', 'Lamps|Lampes; Rugs|Tapis; Curtains|Rideaux; Mirrors|Miroirs'),
  ],
  hardware: [
    T('Building materials', 'Matériaux de construction', 'Cement|Ciment; Blocks & bricks|Parpaings & briques; Sand & gravel|Sable & gravier; Iron rods|Fers à béton; Roofing sheets|Tôles; Timber|Bois'),
    T('Tools', 'Outillage', 'Hand tools|Outils à main; Power tools|Outils électriques; Measuring tools|Instruments de mesure'),
    T('Electrical', 'Électricité', 'Cables & wires|Câbles & fils; Switches & sockets|Interrupteurs & prises; Bulbs & lighting|Ampoules & éclairage; Breakers|Disjoncteurs'),
    T('Plumbing', 'Plomberie', 'Pipes|Tuyaux; Fittings|Raccords; Taps|Robinets; Tanks|Réservoirs'),
    T('Paint', 'Peinture', 'Interior paint|Peinture intérieure; Exterior paint|Peinture extérieure; Brushes & rollers|Pinceaux & rouleaux; Thinner|Diluant'),
    T('Fasteners', 'Visserie', 'Nails|Clous; Screws|Vis; Bolts & nuts|Boulons & écrous'),
    T('Safety', 'Sécurité', 'Gloves|Gants; Helmets|Casques; Safety boots|Chaussures de sécurité'),
  ],
  automotive: [
    T('Spare parts', 'Pièces détachées', 'Engine parts|Pièces moteur; Brakes|Freins; Filters|Filtres; Suspension|Suspension; Electrical parts|Pièces électriques'),
    T('Lubricants & fluids', 'Lubrifiants & liquides', 'Engine oil|Huile moteur; Brake fluid|Liquide de frein; Coolant|Liquide de refroidissement; Grease|Graisse'),
    T('Tyres & wheels', 'Pneus & jantes'),
    T('Batteries', 'Batteries'),
    T('Accessories', 'Accessoires', 'Seat covers|Housses de siège; Floor mats|Tapis de sol; Phone holders|Supports téléphone'),
    T('Motorcycle parts', 'Pièces moto', 'Engine parts|Pièces moteur; Tyres|Pneus; Chains & sprockets|Chaînes & pignons'),
    T('Tools', 'Outils', undefined, 'general'),
  ],
  sports: [
    T('Football', 'Football', 'Balls|Ballons; Jerseys|Maillots; Football boots|Crampons; Shin guards|Protège-tibias'),
    T('Fitness', 'Fitness', 'Weights|Haltères; Mats|Tapis; Resistance bands|Élastiques'),
    T('Team sports', 'Sports collectifs', 'Basketball|Basketball; Volleyball|Volleyball; Handball|Handball'),
    T('Racket sports', 'Sports de raquette', 'Tennis|Tennis; Table tennis|Tennis de table; Badminton|Badminton'),
    T('Sportswear', 'Vêtements de sport', 'Tracksuits|Survêtements; Shorts|Shorts; Leggings|Leggings', 'clothing'),
    T('Sports shoes', 'Chaussures de sport', undefined, 'footwear'),
    T('Outdoor & camping', 'Plein air & camping'), T('Cycling', 'Cyclisme'),
    T('Accessories', 'Accessoires', 'Sports bags|Sacs de sport; Bottles|Gourdes; Protective gear|Protections'),
  ],
  toys: [
    T('Baby toys', 'Jouets bébé'), T('Dolls & figures', 'Poupées & figurines'), T('Educational toys', 'Jouets éducatifs'),
    T('Building blocks', 'Jeux de construction'), T('Cars & vehicles', 'Voitures & véhicules'), T('Outdoor toys', 'Jeux d’extérieur'),
    T('Board games & puzzles', 'Jeux de société & puzzles'), T('Electronic toys', 'Jouets électroniques'), T('Party supplies', 'Articles de fête'),
  ],
  books: [
    T('School textbooks', 'Manuels scolaires', 'Nursery|Maternelle; Primary|Primaire; Secondary|Secondaire; University|Université'),
    T('Fiction', 'Romans'), T('Non-fiction', 'Documentaires & essais'), T('Children’s books', 'Livres pour enfants'),
    T('Religious books', 'Livres religieux'), T('Dictionaries & reference', 'Dictionnaires & ouvrages de référence'),
    T('Exam preparation', 'Préparation aux examens'), T('Magazines', 'Magazines'),
  ],
  stationery: [
    T('Paper', 'Papeterie', 'Exercise books|Cahiers; Notebooks|Carnets; Printing paper|Papier d’impression; Envelopes|Enveloppes'),
    T('Writing', 'Écriture', 'Pens|Stylos; Pencils|Crayons; Markers|Marqueurs; Erasers|Gommes'),
    T('School supplies', 'Fournitures scolaires', 'School bags|Cartables; Geometry sets|Kits de géométrie; Rulers|Règles; Calculators|Calculatrices'),
    T('Office supplies', 'Fournitures de bureau', 'Files & folders|Chemises & classeurs; Staplers|Agrafeuses; Tape|Ruban adhésif; Ink & toner|Encre & toner'),
    T('Art & craft', 'Arts & loisirs créatifs'),
  ],
  jewelry: [
    T('Rings', 'Bagues'), T('Necklaces & chains', 'Colliers & chaînes'), T('Earrings', 'Boucles d’oreilles'),
    T('Bracelets & bangles', 'Bracelets'), T('Watches', 'Montres'), T('Wedding & engagement', 'Mariage & fiançailles'),
    T('Men’s jewelry', 'Bijoux homme'), T('Fashion jewelry', 'Bijoux fantaisie'),
  ],
  pets: [
    T('Dogs', 'Chiens', 'Food|Nourriture; Treats|Friandises; Toys|Jouets; Beds|Couchages; Collars & leads|Colliers & laisses'),
    T('Cats', 'Chats', 'Food|Nourriture; Litter|Litière; Toys|Jouets'),
    T('Birds', 'Oiseaux'), T('Fish & aquarium', 'Poissons & aquarium'),
    T('Poultry & livestock feed', 'Aliments volaille & bétail', undefined, 'grocery'), T('Health & grooming', 'Santé & toilettage'),
  ],
  agriculture: [
    T('Seeds & seedlings', 'Semences & plants'), T('Fertilizers', 'Engrais'),
    T('Crop protection', 'Protection des cultures', 'Herbicides|Herbicides; Pesticides|Pesticides; Fungicides|Fongicides'),
    T('Animal feed', 'Aliments pour animaux'), T('Veterinary products', 'Produits vétérinaires'),
    T('Tools & equipment', 'Outils & équipements', 'Hoes & machetes|Houes & machettes; Sprayers|Pulvérisateurs; Irrigation|Irrigation', 'general'),
    T('Poultry equipment', 'Matériel avicole', undefined, 'general'), T('Produce', 'Récoltes & produits'),
  ],
  home_goods: [
    T('Kitchen', 'Cuisine', 'Cookware|Batterie de cuisine; Utensils|Ustensiles; Plates & cups|Assiettes & tasses; Storage containers|Boîtes de conservation'),
    T('Bedding', 'Linge de lit', 'Sheets|Draps; Blankets|Couvertures; Pillows|Oreillers'),
    T('Bathroom', 'Salle de bain', 'Towels|Serviettes; Bathroom accessories|Accessoires de salle de bain'),
    T('Cleaning', 'Nettoyage'),
    T('Decor', 'Décoration', 'Curtains|Rideaux; Rugs|Tapis; Frames|Cadres; Vases|Vases'),
    T('Small appliances', 'Petit électroménager', 'Kettles|Bouilloires; Blenders|Mixeurs; Irons|Fers à repasser; Fans|Ventilateurs'),
    T('Lighting', 'Éclairage'),
  ],
  gifts: [
    T('Gift sets', 'Coffrets cadeaux'), T('Greeting cards', 'Cartes de vœux'), T('Gift wrap & bags', 'Emballages & sacs cadeaux'),
    T('Flowers', 'Fleurs'), T('Souvenirs & crafts', 'Souvenirs & artisanat'), T('Party & celebration', 'Fêtes & célébrations'),
    T('Personalised gifts', 'Cadeaux personnalisés'), T('Perfume gift sets', 'Coffrets parfum', undefined, 'beauty'),
  ],
  general: [
    T('Food & drinks', 'Alimentation & boissons', undefined, 'grocery'), T('Household', 'Entretien ménager'),
    T('Personal care', 'Hygiène & beauté', undefined, 'beauty'), T('Electronics & accessories', 'Électronique & accessoires', undefined, 'electronics'),
    T('Clothing & accessories', 'Vêtements & accessoires', undefined, 'clothing'), T('Stationery', 'Papeterie'),
    T('Hardware', 'Quincaillerie'), T('Others', 'Divers'),
  ],
  other: [T('Products', 'Produits'), T('Others', 'Divers')],
};

export interface TemplateCategory { name: string; attribute_set?: AttributeSet; children: string[] }

// Template for a business type in the given language, ready to send to the server.
export function categoryTemplate(type: string, lang: 'en' | 'fr'): TemplateCategory[] {
  const tops = CATEGORY_TEMPLATES[(BUSINESS_TYPES as readonly string[]).includes(type) ? type as BusinessType : 'general'];
  const set = DEFAULT_ATTRIBUTE_SET[(type as BusinessType)] ?? 'general';
  return tops.map((c) => ({
    name: lang === 'fr' ? c.fr : c.en,
    attribute_set: c.set ?? set,
    children: (c.sub ?? '').split(';').map((p) => p.trim()).filter(Boolean).map((p) => { const [en, fr] = p.split('|'); return (lang === 'fr' ? fr : en).trim(); }),
  }));
}

// ---------------------------------------------------------------------------
// Optional product details per attribute set
// ---------------------------------------------------------------------------
export interface AttributeField { key: string; kind?: 'text' | 'number' | 'select'; options?: string[]; unit?: string; placeholder?: string }

const COLOR: AttributeField = { key: 'color', placeholder: 'Black, Red…' };
const SIZE: AttributeField = { key: 'size', placeholder: 'S, M, L, XL…' };
const MATERIAL: AttributeField = { key: 'material', placeholder: 'Cotton, Leather…' };
const MODEL: AttributeField = { key: 'model' };
const WEIGHT: AttributeField = { key: 'weight', placeholder: '1.5 kg' };
const DIMENSIONS: AttributeField = { key: 'dimensions', placeholder: '120 × 60 × 75 cm' };
const WARRANTY: AttributeField = { key: 'warranty_months', kind: 'number', unit: 'months' };
const SERIAL: AttributeField = { key: 'serial_number' };
const GENDER: AttributeField = { key: 'gender', kind: 'select', options: ['men', 'women', 'kids', 'baby', 'unisex'] };

export const ATTRIBUTE_FIELDS: Record<AttributeSet, AttributeField[]> = {
  clothing: [SIZE, COLOR, GENDER, MATERIAL],
  footwear: [{ key: 'shoe_size', placeholder: '42, 43…' }, COLOR, GENDER, MATERIAL],
  electronics: [MODEL, { key: 'capacity', placeholder: '128 GB, 8 GB RAM…' }, COLOR, SERIAL, { key: 'imei', placeholder: '15 digits' }, WARRANTY],
  hair: [{ key: 'length', placeholder: '16 inches' }, { key: 'texture', kind: 'select', options: ['straight', 'body_wave', 'deep_wave', 'water_wave', 'curly', 'kinky'] },
    COLOR, { key: 'hair_type', kind: 'select', options: ['human', 'synthetic', 'blend'] }, { key: 'size', placeholder: '100 g, 3 bundles…' }],
  beauty: [{ key: 'shade', placeholder: 'Nude, 120…' }, { key: 'volume', placeholder: '50 ml, 200 g' }, { key: 'skin_type' }],
  grocery: [{ key: 'package_size', placeholder: '500 g, 1.5 L, 24 × 33 cl' }],
  furniture: [DIMENSIONS, MATERIAL, COLOR, WEIGHT],
  jewelry: [{ key: 'metal', kind: 'select', options: ['gold', 'silver', 'stainless_steel', 'plated', 'other'] }, { key: 'purity', placeholder: '18k, 925' }, WEIGHT, SIZE, { key: 'stone' }],
  automotive: [{ key: 'part_number' }, { key: 'compatible_vehicles', placeholder: 'Toyota Corolla 2010–2015' }, MODEL],
  books: [{ key: 'author' }, { key: 'publisher' }, { key: 'edition' }, { key: 'language' }],
  general: [COLOR, SIZE, MODEL, WEIGHT, DIMENSIONS, SERIAL, WARRANTY],
};

// GTIN (EAN-8, UPC-A, EAN-13, GTIN-14) check digit. Other barcode types are accepted as typed.
export function barcodeProblem(code: string): 'check_digit' | null {
  const v = code.trim();
  if (!/^\d+$/.test(v) || ![8, 12, 13, 14].includes(v.length)) return null;
  const digits = v.split('').map(Number);
  const check = digits.pop()!;
  const sum = digits.reverse().reduce((s, d, i) => s + d * (i % 2 === 0 ? 3 : 1), 0);
  return (10 - (sum % 10)) % 10 === check ? null : 'check_digit';
}

export const COMMON_UNITS = ['piece', 'pair', 'pack', 'box', 'carton', 'dozen', 'bottle', 'can', 'sachet', 'bag', 'roll', 'set',
  'kg', 'g', 'litre', 'ml', 'metre', 'cm', 'bundle', 'yard'];
