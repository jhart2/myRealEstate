# frozen_string_literal: true

puts "Seeding TT Realty…"

Favorite.destroy_all
Inquiry.destroy_all
Subscription.destroy_all
Property.destroy_all
Agent.destroy_all
Session.destroy_all
User.destroy_all

admin = User.create!(
  name: "Alex Morgan",
  email_address: "admin@estate.realty",
  password: "password123",
  password_confirmation: "password123",
  role: :admin
)

buyer = User.create!(
  name: "Jordan Lee",
  email_address: "buyer@estate.realty",
  password: "password123",
  password_confirmation: "password123",
  role: :buyer
)

agents_data = [
  {
    name: "Catherine Wells",
    title: "Senior Property Advisor",
    sales_volume: "$94M",
    years_experience: 20,
    email: "catherine@estate.realty",
    phone: "+1 (310) 555-0142",
    bio: "Catherine specializes in Westside estates and off-market opportunities with twenty years advising private clients.",
    image_url: "https://images.unsplash.com/photo-1581065178047-8ee15951ede6?w=400&h=500&fit=crop&auto=format",
    user_email: "catherine@estate.realty"
  },
  {
    name: "Marcus Osei",
    title: "Luxury Estates Specialist",
    sales_volume: "$76M",
    years_experience: 14,
    email: "marcus@estate.realty",
    phone: "+1 (212) 555-0198",
    bio: "Marcus leads high-value residential placements across Manhattan and the Hamptons.",
    image_url: "https://images.unsplash.com/photo-1647580427155-0483906cb9de?w=400&h=500&fit=crop&auto=format",
    user_email: "marcus@estate.realty"
  },
  {
    name: "Sophia Larsen",
    title: "Commercial & Residential",
    sales_volume: "$128M",
    years_experience: 18,
    email: "sophia@estate.realty",
    phone: "+1 (312) 555-0177",
    bio: "Sophia bridges commercial conversions and residences for investors who want both yield and lifestyle.",
    image_url: "https://images.unsplash.com/photo-1770199105692-9e52ff137cad?w=400&h=500&fit=crop&auto=format",
    user_email: "sophia@estate.realty"
  },
  {
    name: "James Delacroix",
    title: "Investment Properties",
    sales_volume: "$61M",
    years_experience: 11,
    email: "james@estate.realty",
    phone: "+1 (415) 555-0133",
    bio: "James focuses on multi-family and coastal assets with a quantitative, long-hold approach.",
    image_url: "https://images.unsplash.com/photo-1610631066894-62452ccb927c?w=400&h=500&fit=crop&auto=format",
    user_email: "james@estate.realty"
  }
]

agents = agents_data.map do |attrs|
  user_email = attrs.delete(:user_email)
  user = User.create!(
    name: attrs[:name],
    email_address: user_email,
    password: "password123",
    password_confirmation: "password123",
    role: :agent
  )
  Agent.create!(attrs.merge(active: true, show_on_homepage: false, listings_count: 0, user: user))
end

properties = [
  {
    tag: "sale", property_type: "Villa", title: "Meridian House",
    address: "12 Saddle Road", city: "Maraval", state: "Trinidad", zip: "",
    latitude: 10.7015, longitude: -61.5278,
    price_cents: 475_000_000, beds: 5, baths: 4, sqft: 5820, featured: true, agent: agents[0],
    image_url: "https://images.unsplash.com/photo-1613490493576-7fde63acd811?w=1200&h=800&fit=crop&auto=format",
    description: "A sculptural villa on a quiet Maraval rise. Floor-to-ceiling glass, a private courtyard, and an upper terrace with Northern Range light from morning until dusk."
  },
  {
    tag: "sale", property_type: "Penthouse", title: "The Aldridge",
    address: "88 Ariapita Avenue", city: "Port of Spain", state: "Trinidad", zip: "",
    latitude: 10.6628, longitude: -61.5185,
    price_cents: 820_000_000, beds: 4, baths: 3, sqft: 4100, featured: true, agent: agents[1],
    image_url: "https://images.unsplash.com/photo-1630699144035-c0f6311ec482?w=800&h=560&fit=crop&auto=format",
    description: "Full-floor penthouse above Woodbrook with wraparound terrace, chef kitchen, and museum-quality finishes. Gulf and city views with deeded parking."
  },
  {
    tag: "rent", property_type: "Apartment", title: "Cortland Lofts",
    address: "45 Coffee Street", city: "San Fernando", state: "Trinidad", zip: "",
    latitude: 10.2820, longitude: -61.4585,
    price_cents: 640_000, beds: 3, baths: 2, sqft: 2340, featured: false, agent: agents[2],
    image_url: "https://images.unsplash.com/photo-1724582586529-62622e50c0b3?w=800&h=560&fit=crop&auto=format",
    description: "Converted warehouse loft near the San Fernando waterfront with original timber beams, polished concrete, and a south-facing wall of light."
  },
  {
    tag: "sale", property_type: "Modern Home", title: "Solstice Estate",
    address: "7 Tucker Valley Road", city: "Chaguaramas", state: "Trinidad", zip: "",
    latitude: 10.6885, longitude: -61.6382,
    price_cents: 610_000_000, beds: 6, baths: 5, sqft: 7200, featured: false, agent: agents[0],
    image_url: "https://images.unsplash.com/photo-1783125127082-3fb6c1bccd72?w=800&h=560&fit=crop&auto=format",
    description: "Coast-adjacent modern estate with infinity pool, guest pavilion, and tropical gardens opening toward the Bocas."
  },
  {
    tag: "rent", property_type: "Apartment", title: "Park Row Residences",
    address: "300 Western Main Road", city: "Westmoorings", state: "Trinidad", zip: "",
    latitude: 10.6755, longitude: -61.5585,
    price_cents: 420_000, beds: 2, baths: 2, sqft: 1580, featured: false, agent: agents[1],
    image_url: "https://images.unsplash.com/photo-1688646953306-5ec93eab8c06?w=800&h=560&fit=crop&auto=format",
    description: "Bright corner residence overlooking the waterfront canopy. Custom millwork, soaking tub, and reserved garage parking."
  },
  {
    tag: "sale", property_type: "Villa", title: "Casa del Cielo",
    address: "3 Cascade Road", city: "Cascade", state: "Trinidad", zip: "",
    latitude: 10.6850, longitude: -61.5120,
    price_cents: 345_000_000, beds: 4, baths: 3, sqft: 4600, featured: false, agent: agents[3],
    image_url: "https://images.unsplash.com/photo-1783125127094-ea962d41ba42?w=800&h=560&fit=crop&auto=format",
    description: "Hillside villa with tiled courtyards, a wine cellar, and sunset views across Port of Spain and the gulf."
  },
  {
    tag: "new", property_type: "House", title: "Harborline Residences",
    address: "19 Invaders Bay", city: "Port of Spain", state: "Trinidad", zip: "",
    latitude: 10.6505, longitude: -61.5300,
    price_cents: 189_000_000, beds: 3, baths: 3, sqft: 2400, featured: true, agent: agents[2],
    image_url: "https://images.unsplash.com/photo-1566908829550-e6551b00979b?w=800&h=560&fit=crop&auto=format",
    description: "Brand-new waterfront townhome on Invaders Bay with rooftop deck, EV charging, and harbor-facing glass."
  },
  {
    tag: "sale", property_type: "Commercial", title: "Atelier 44",
    address: "44 Independence Square", city: "Port of Spain", state: "Trinidad", zip: "",
    latitude: 10.6495, longitude: -61.5110,
    price_cents: 520_000_000, beds: 0, baths: 2, sqft: 6800, featured: false, agent: agents[3],
    image_url: "https://images.unsplash.com/photo-1770622006495-86de934162b5?w=800&h=560&fit=crop&auto=format",
    description: "Flagship-ready commercial floor facing Independence Square with restored façade, freight access, and fully renewed MEP systems."
  }
]

properties.each do |attrs|
  Property.create!(attrs.merge(status: "active"))
end

Agent.find_each { |agent| Agent.reset_counters(agent.id, :properties) }

Inquiry.create!(
  name: buyer.name,
  email: buyer.email_address,
  phone: "+1 (555) 010-2000",
  message: "I'd love a private tour of Meridian House this weekend.",
  property: Property.find_by(title: "Meridian House"),
  user: buyer,
  status: "new"
)

Subscription.create!(email: "newsletter@example.com", active: true)
buyer.favorites.create!(property: Property.find_by(title: "The Aldridge"))

puts "Done."
puts "Admin: admin@estate.realty / password123"
puts "Agent: catherine@estate.realty / password123 (portal at /portal)"
puts "Buyer: buyer@estate.realty / password123"
puts "Properties: #{Property.count}, Agents: #{Agent.count}"
