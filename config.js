// Valentino The Barber: site settings
// supabaseUrl and supabaseAnonKey come from Supabase > Project Settings > API Keys (publishable key).
// Until both are filled in, the booking button shows the shop's phone and WhatsApp
// (or sends people to fallbackUrl, if you set it, e.g. the old Fresha link).
window.VALENTINO_CONFIG = {
  supabaseUrl: 'https://jvvcfefyxcgbnybhqldz.supabase.co',
  supabaseAnonKey: 'sb_publishable_F6q0ruqTrHcbJWaWwSWCiA_bYxVekHv', // publishable key, safe to be public
  shopNumber: '+59996720190',
  houseCallNumber: '+59996720190', // replace with Valentino's house call number
  fallbackUrl: 'https://www.fresha.com/book-now/valentino-barbershop-j4pgmody/all-offer?share=true&pId=2695702'
};
