defmodule Xylon.Conference.DoctestTest do
  use ExUnit.Case, async: false

  setup do
    Xylon.Catalogue.reset!()
    :ok
  end

  doctest Xylon.Conference
  doctest Xylon.Conference.AudioLevel
  doctest Xylon.Conference.Mcu.CodecBind
  doctest Xylon.Conference.Mcu.Mixer
  doctest Xylon.Conference.OfferTracks
  doctest Xylon.Conference.Rewrite
end
