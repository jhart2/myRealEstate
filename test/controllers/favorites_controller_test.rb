require "test_helper"

class FavoritesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @agent = Agent.create!(
      name: "Fav Agent",
      title: "Agent",
      email: "fav-agent@example.com",
      phone: "555-0101",
      sales_volume: "$1M",
      years_experience: 1,
      bio: "Test",
      active: true
    )
    @user = User.create!(
      name: "Buyer",
      email_address: "buyer-fav@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: :buyer
    )
    @property = Property.create!(
      title: "Fav Home",
      address: "1 Test Rd",
      city: "Port of Spain",
      state: "TT",
      zip: "00000",
      price_cents: 500_000_00,
      tag: "sale",
      property_type: "House",
      status: "active",
      beds: 2,
      baths: 1,
      featured: false,
      agent: @agent
    )
    post session_path, params: { email_address: @user.email_address, password: "password123" }
  end

  test "create saves favorite via turbo stream without redirect flash page" do
    assert_difference -> { @user.favorites.count }, 1 do
      post property_favorite_path(@property),
           params: { variant: "carousel" },
           as: :turbo_stream
    end

    assert_response :success
    assert_includes response.media_type, "turbo-stream"
    assert_match(/favorite_heart_property_#{@property.id}/, response.body)
    assert_includes response.body, "text-[#e11d48]"
  end

  test "destroy removes favorite via turbo stream" do
    @user.favorites.create!(property: @property)

    assert_difference -> { @user.favorites.count }, -1 do
      delete property_favorite_path(@property),
             params: { variant: "carousel" },
             as: :turbo_stream
    end

    assert_response :success
    assert_includes response.media_type, "turbo-stream"
  end
end
