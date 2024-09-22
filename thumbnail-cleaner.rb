#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'

class ThumbnailCleaner
  ARCHIVE_DIR = 'archive'
  THUMBNAIL_MAX_SIZE = 10 * 1024 # 10KB in bytes

  def self.clean
    new.clean
  end

  def clean
    puts "Starting thumbnail cleanup in #{ARCHIVE_DIR}..."

    Dir.glob(File.join(ARCHIVE_DIR, '**', '*')).each do |file|
      next unless File.file?(file) && image_file?(file)

      remove_file(file) if File.size(file) < THUMBNAIL_MAX_SIZE
    end

    puts 'Thumbnail cleanup complete!'
  end

  private

  def image_file?(file)
    %w[.jpg .jpeg .png .gif].include?(File.extname(file).downcase)
  end

  def remove_file(file)
    puts "Removing thumbnail: #{file}"
    FileUtils.rm(file)
  rescue StandardError => e
    puts "Error removing file #{file}: #{e.message}"
  end
end

ThumbnailCleaner.clean
