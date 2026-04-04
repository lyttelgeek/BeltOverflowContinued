data:extend(
  {
    {
      type = "int-setting",
      name = "belt_overflow_poll_frequency",
      setting_type = "runtime-global",
      default_value = 5,
      minimum_value = 1,
      maximum_value = 60
    },
    {
      type = "int-setting",
      name = "belt_overflow_hot_cap",
      setting_type = "runtime-global",
      default_value = 20,
      minimum_value = 1,
      maximum_value = 200
    },
    {
      type = "bool-setting",
      name = "belt_overflow_draw_indicators",
      setting_type = "runtime-global",
      default_value = false
    }
  }
)
