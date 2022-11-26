#!/usr/bin/env ruby
# frozen_string_literal: false

require 'English'
require 'base64'
require 'builder'
require 'csv'
require 'digest/bubblebabble'
require 'fileutils'
require 'json'
require 'loofah'
require 'nokogiri'
require 'optimist'
require 'yaml'
require 'etc'

require File.expand_path('../../../lib/recordandplayback', __FILE__)
require File.expand_path('../../../lib/recordandplayback/interval_tree', __FILE__)

include IntervalTree

opts = Optimist.options do
  opt :meeting_id, 'Meeting id to archive', type: String
  opt :format, 'Playback format name', type: String
  opt :log_stdout, 'Log to STDOUT', type: :flag
end

meeting_id = opts[:meeting_id]
playback = opts[:format]

exit(0) if playback != 'presentation'

logger = opts[:log_stdout] ? Logger.new($stdout) : Logger.new('/var/log/bigbluebutton/post_publish.log', 'weekly')
logger.level = Logger::INFO
BigBlueButton.logger = logger

BigBlueButton.logger.info("Started exporting presentation for [#{meeting_id}]")

@published_files = "/var/bigbluebutton/published/presentation/#{meeting_id}"

# Creates scratch directories
FileUtils.mkdir_p(["#{@published_files}/chats", "#{@published_files}/cursor", "#{@published_files}/frames",
                   "#{@published_files}/timestamps", "/var/bigbluebutton/published/video/#{meeting_id}"])

TEMPORARY_FILES_PERMISSION = 0o600

# Setting the SVGZ option to true will write less data on the disk.
SVGZ_COMPRESSION = true

# Set this to true if you've recompiled FFmpeg to enable external references. Writes less data on disk
FFMPEG_REFERENCE_SUPPORT = false
BASE_URI = FFMPEG_REFERENCE_SUPPORT ? "-base_uri #{@published_files}" : ''

# Set this to true if you've recompiled FFmpeg with the movtext codec enabled
CAPTION_SUPPORT = false

# Video output quality: 0 is lossless, 51 is the worst. Default 23, 18 - 28 recommended
CONSTANT_RATE_FACTOR = 23

SVG_EXTENSION = SVGZ_COMPRESSION ? 'svgz' : 'svg'
VIDEO_EXTENSION = File.file?("#{@published_files}/video/webcams.mp4") ? 'mp4' : 'webm'

# Set this to true if the whiteboard supports whiteboard animations
REMOVE_REDUNDANT_SHAPES = false

BENCHMARK_FFMPEG = false
BENCHMARK = BENCHMARK_FFMPEG ? '-benchmark ' : ''

THREADS = p Etc.nprocessors

# Styling config
BORDER_RADIUS = 30
COMPONENT_MARGIN = 30

CURSOR_RADIUS = 8

# Output video size
OUTPUT_WIDTH = 1920
OUTPUT_HEIGHT = 1080

# Whiteboard/Deskshare/Slides config
SLIDES_WIDTH = 1500 - 2 * COMPONENT_MARGIN
SLIDES_HEIGHT = SLIDES_WIDTH * 9 / 16
SLIDES_X = COMPONENT_MARGIN
SLIDES_Y = COMPONENT_MARGIN

HIDE_DESKSHARE = false

WhiteboardElement = Struct.new(:begin, :end, :value, :id)
WhiteboardSlide = Struct.new(:href, :begin, :end, :width, :height)

# Webcams config
WEBCAMS_WIDTH = OUTPUT_WIDTH - SLIDES_WIDTH - 3 * COMPONENT_MARGIN
WEBCAMS_HEIGHT = WEBCAMS_WIDTH * 3 / 4
WEBCAMS_X = SLIDES_WIDTH + 2 * COMPONENT_MARGIN
WEBCAMS_Y = COMPONENT_MARGIN

# Chat config
CHAT_BOTTOM_MARGIN = 90
CHAT_PADDING = 20

CHAT_OUTER_WIDTH = WEBCAMS_WIDTH
CHAT_OUTER_HEIGHT = OUTPUT_HEIGHT - WEBCAMS_HEIGHT - 2 * COMPONENT_MARGIN - CHAT_BOTTOM_MARGIN
CHAT_OUTER_X = SLIDES_WIDTH + 2 * COMPONENT_MARGIN
CHAT_OUTER_Y = WEBCAMS_HEIGHT + 2 * COMPONENT_MARGIN

CHAT_WIDTH = CHAT_OUTER_WIDTH - 2 * CHAT_PADDING
CHAT_HEIGHT = CHAT_OUTER_HEIGHT - 2 * CHAT_PADDING
CHAT_X = CHAT_PADDING
CHAT_Y = CHAT_PADDING

CHAT_BG_COLOR = "0x000000" # black (ffmpeg syntax)
CHAT_FG_COLOR = "#ffffff" # white (css syntax)

HIDE_CHAT = false
HIDE_CHAT_NAMES = false

# Assumes a monospaced font with a width to aspect ratio of 3:5
CHAT_FONT_SIZE = 15
CHAT_FONT_SIZE_X = (0.6 * CHAT_FONT_SIZE).to_i
CHAT_STARTING_OFFSET = CHAT_HEIGHT + CHAT_FONT_SIZE

# Max. dimensions supported: 8032 x 32767
CHAT_CANVAS_WIDTH = (8032 / CHAT_WIDTH) * CHAT_WIDTH
CHAT_CANVAS_HEIGHT = (32_767 / CHAT_FONT_SIZE) * CHAT_FONT_SIZE

BACK_SLASH = '\\'


def run_command(command, silent = false)
  BigBlueButton.logger.info("Running: #{command}") unless silent
  output = `#{command}`
  [$CHILD_STATUS.success?, output]
end

def add_captions
  json = JSON.parse(File.read("#{@published_files}/captions.json"))
  caption_amount = json.length

  return if caption_amount.zero?

  caption_input = ''
  maps = ''
  language_names = ''

  (0..caption_amount - 1).each do |i|
     caption = json[i]
     caption_input << "-i #{@published_files}/caption_#{caption['locale']}.vtt "
     maps << "-map #{i + 1} "
     language_names << "-metadata:s:s:#{i} language=#{caption['localeName'].downcase[0..2]} "
  end

  render = "ffmpeg -i #{@published_files}/meeting-tmp.mp4 #{caption_input} " \
           "-map 0:v -map 0:a #{maps} -c:v copy -c:a copy -c:s mov_text #{language_names} " \
           "-y #{@published_files}/meeting_captioned.mp4"

  success, = run_command(render)
  if success
    FileUtils.mv("#{@published_files}/meeting_captioned.mp4", "#{@published_files}/meeting-tmp.mp4")
  else
    warn('An error occurred adding the captions to the video.')
      exit(false)
  end
end

def add_chapters(duration, slides)
  # Extract metadata
  command = "ffmpeg -i #{@published_files}/meeting-tmp.mp4 -y -f ffmetadata #{@published_files}/meeting_metadata"

  success, = run_command(command)
  unless success
    warn("An error occurred extracting the video's metadata.")
    exit(false)
  end

  slide_number = 1
  deskshare_number = 1

  chapter = ''
  slides.each do |slide|
    chapter_start = slide.begin
    chapter_end = slide.end

    break if chapter_start >= duration

    next if (chapter_end - chapter_start) <= 0.25

    if slide.href.include?('deskshare')
      title = "Screen sharing #{deskshare_number}"
      deskshare_number += 1
    else
      title = "Slide #{slide_number}"
      slide_number += 1
    end

    chapter << "[CHAPTER]\nSTART=#{chapter_start * 1e9}\nEND=#{chapter_end * 1e9}\ntitle=#{title}\n\n"
  end

  File.open("#{@published_files}/meeting_metadata", 'a') do |file|
    file << chapter
  end

  render = "ffmpeg -i #{@published_files}/meeting-tmp.mp4 " \
           "-i #{@published_files}/meeting_metadata -map_metadata 1 " \
           "-map_chapters 1 -codec copy -y -t #{duration} #{@published_files}/meeting_chapters.mp4"

  success, = run_command(render)
  if success
    FileUtils.mv("#{@published_files}/meeting_chapters.mp4", "#{@published_files}/meeting-tmp.mp4")
  else
    warn('Failed to add the chapters to the video.')
    exit(false)
  end
end

def add_greenlight_buttons(metadata)
  bbb_props = File.open(File.join(__dir__, '../bigbluebutton.yml')) { |f| YAML.safe_load(f) }
  playback_protocol = bbb_props['playback_protocol']
  playback_host = bbb_props['playback_host']

  meeting_id = metadata.xpath('recording/id').inner_text

  metadata.xpath('recording/playback/format').children.first.content = 'video'
  metadata.xpath('recording/playback/link').children.first.content = "#{playback_protocol}://#{playback_host}/presentation/#{meeting_id}/meeting.mp4"

  File.open("/var/bigbluebutton/published/video/#{meeting_id}/metadata.xml", 'w') do |file|
    file.write(metadata)
  end
end

def base64_encode(path)
  return '' if File.directory?(path)

  data = File.open(path).read
  "data:image/#{File.extname(path).delete('.')};base64,#{Base64.strict_encode64(data)}"
end

def measure_string(s, font_size)
  # https://stackoverflow.com/a/4081370
  # DejaVuSans, the default truefont of Debian, can be used here
  # /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
  # use ImageMagick to measure the string in pixels
  command = "convert xc: -font /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf -pointsize #{font_size} -debug annotate -annotate 0 #{Shellwords.escape(s).gsub(BACK_SLASH * 2){ BACK_SLASH * 4 }} null: 2>&1"
  _, output = run_command(command, true)
  output.match(/; width: (\d+);/)[1].to_f
end

def pack_up_string(s, separator, font_size, text_box_width)
  # split the line on whitespaces, and measure the line to fit into
  # the text_box_width
  line_breaks = []
  queued_words = []
  s.split(separator).each do |word|
    # first consider queued word and the current word in the line
    test_string = (queued_words + [word]).join(separator)

    width = measure_string(test_string, font_size)

    if width > text_box_width
      # line exceeded, so consider the queued words as a line break and
      # queue the current word
      line_breaks += [queued_words.join(separator)]
      if measure_string(word, font_size) > text_box_width
        # if the word alone exceeds the box width, then we pack the word
        # maximizing the amount of characters on each line
        res = pack_up_string(word, '', font_size, text_box_width)
        # queue last line break, other words might fit
        queued_words = [res.pop]
        line_breaks += res
      else
        queued_words = [word]
      end
    else
      # current word fits the text box, so keep enqueueing new words
      queued_words += [word]
    end
  end
  # make sure we release the final queued words as the final line break
  line_breaks += [queued_words.join(separator)] unless queued_words.empty?

  line_breaks
end

def convert_whiteboard_shapes(whiteboard)
  # Find shape elements
  whiteboard.xpath('svg/g/g').each do |annotation|
    # Make all annotations visible
    style = annotation.attr('style')
    style.sub! 'visibility:hidden', ''
    annotation.set_attribute('style', style)

    shape = annotation.attribute('shape').to_s
    # Convert polls to data schema
    if shape.include? 'poll'
      poll = annotation.element_children.first

      path = "#{@published_files}/#{poll.attribute('href')}"
      poll.remove_attribute('href')

      # Namespace xmlns:xlink is required by FFmpeg
      poll.add_namespace_definition('xlink', 'http://www.w3.org/1999/xlink')

      data = FFMPEG_REFERENCE_SUPPORT ? "file://#{path}" : base64_encode(path)

      poll.set_attribute('xlink:href', data)
    end

    # Convert XHTML to SVG so that text can be shown
    next unless shape.include? 'text'

    # Turn style attributes into a hash
    style_values = Hash[*CSV.parse(style, col_sep: ':', row_sep: ';').flatten]

    # The text_color variable may not be required depending on your FFmpeg version
    text_color = style_values['color']
    font_size = style_values['font-size'].to_f

    annotation.set_attribute('style', "#{style};fill:currentcolor")

    foreign_object = annotation.xpath('switch/foreignObject')

    # Obtain X and Y coordinates of the text
    x = foreign_object.attr('x').to_s
    y = foreign_object.attr('y').to_s
    text_box_width = foreign_object.attr('width').to_s.to_f

    text = foreign_object.children.children

    builder = Builder::XmlMarkup.new
    builder.text(x: x, y: y, fill: text_color, 'xml:space' => 'preserve') do
      previous_line_was_text = true

      text.each do |line|
        line = line.to_s

        if line == '<br/>'
          if previous_line_was_text
            previous_line_was_text = false
          else
            builder.tspan(x: x, dy: '1.0em') { builder << '<br/>' }
          end
        else
          line = Loofah.fragment(line).scrub!(:strip).text.unicode_normalize

          line_breaks = pack_up_string(line, ' ', font_size, text_box_width)

          line_breaks.each do |row|
            safe_message = Loofah.fragment(row).scrub!(:escape)
            builder.tspan(x: x, dy: '1.0em') { builder << safe_message }
          end

          previous_line_was_text = true
        end
      end
    end

    annotation.add_child(builder.target!)

    # Remove the <switch> tag
    annotation.xpath('switch').remove
  end

  # Save new shapes.svg copy
  File.open("#{@published_files}/shapes_modified.svg", 'w', TEMPORARY_FILES_PERMISSION) do |file|
    file.write(whiteboard)
  end
end

def parse_panzooms(pan_reader, timestamps)
  panzooms = []
  timestamp = 0

  pan_reader.each do |node|
    next unless node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT

    node_name = node.name

    timestamp = node.attribute('timestamp').to_f if node_name == 'event'

    if node_name == 'viewBox'
      panzooms << [timestamp, node.inner_xml]
      timestamps << timestamp
    end
  end

  [panzooms, timestamps]
end

def parse_whiteboard_shapes(shape_reader)
  slide_in = 0
  slide_out = 0

  shapes = []
  slides = []
  timestamps = []

  shape_reader.each do |node|
    next unless node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT

    node_name = node.name
    node_class = node.attribute('class')

    if node_name == 'image' && node_class == 'slide'
      slide_in = node.attribute('in').to_f
      slide_out = node.attribute('out').to_f

      timestamps << slide_in
      timestamps << slide_out

      # Image paths need to follow the URI Data Scheme (for slides and polls)
      path = "#{@published_files}/#{node.attribute('href')}"

      data = FFMPEG_REFERENCE_SUPPORT ? "file://#{path}" : base64_encode(path)

      slides << WhiteboardSlide.new(data, slide_in, slide_out, node.attribute('width').to_f, node.attribute('height'))
    end

    next unless node_name == 'g' && node_class == 'shape'

    shape_timestamp = node.attribute('timestamp').to_f
    shape_undo = node.attribute('undo').to_f

    shape_undo = slide_out if shape_undo.negative?

    shape_enter = [shape_timestamp, slide_in].max
    shape_leave = [[shape_undo, slide_in].max, slide_out].min

    timestamps << shape_enter
    timestamps << shape_leave

    xml = "<g style=\"#{node.attribute('style')}\">#{node.inner_xml}</g>"
    id = node.attribute('shape').split('-').last

    shapes << WhiteboardElement.new(shape_enter, shape_leave, xml, id)
  end

  [shapes, slides, timestamps]
end

def remove_adjacent(array)
  index = 0

  until array[index + 1].nil?
    array[index] = nil if array[index].id == array[index + 1].id
    index += 1
  end

  array.compact! || array
end

def parse_chat(chat_reader)
  messages = []
  salt = Time.now.nsec

  chat_reader.each do |node|
    unless node.name == 'chattimeline' &&
           node.attribute('target') == 'chat' &&
           node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT
      next
    end

    name = node.attribute('name')
    name = Digest::SHA1.bubblebabble(name << salt.to_s)[0..10] if HIDE_CHAT_NAMES

    messages << [node.attribute('in').to_f, name, node.attribute('message')]
  end

  messages
end

def is_rtl(text)
  ltrChars = "A-Za-z\u{00C0}-\u{00D6}\u{00D8}-\u{00F6}\u{00F8}-\u{02B8}\u{0300}-\u{0590}\u{0800}-\u{1FFF}\u{2C00}-\u{FB1C}\u{FDFE}-\u{FE6F}\u{FEFD}-\u{FFFF}"
  rtlChars = "\u{0591}-\u{07FF}\u{FB1D}-\u{FDFD}\u{FE70}-\u{FEFC}"
  return /^[^#{ltrChars}]*[#{rtlChars}]/.match?(text)
end

def render_chat(chat_reader)
  messages = parse_chat(chat_reader)
  return if messages.empty?

  # Text coordinates on the SVG file
  svg_x = 0
  svg_y = CHAT_STARTING_OFFSET

  # Chat viewbox coordinates
  chat_x = 0
  chat_y = 0

  overlay_position = []

  # Keep last n messages for seamless transitions between columns
  duplicates = Array.new((CHAT_HEIGHT / (3 * CHAT_FONT_SIZE)) + 1) { nil }

  # Create SVG chat with all messages
  # Add 'xmlns' => 'http://www.w3.org/2000/svg' for visual debugging
  builder = Builder::XmlMarkup.new
  builder.instruct!
  builder.svg(width: CHAT_CANVAS_WIDTH, height: CHAT_CANVAS_HEIGHT, 'xmlns' => 'http://www.w3.org/2000/svg') do
    builder.style {
      builder << "
        text{
          font-family: monospace;
          font-size: #{CHAT_FONT_SIZE};
          fill: #{CHAT_FG_COLOR};
        }
      "
    }

    messages.each do |timestamp, name, chat|
      # Strip HTML tags e.g. from links so it only displays the inner text
      chat = Loofah.fragment(chat).scrub!(:strip).text.unicode_normalize
      name = Loofah.fragment(name).scrub!(:strip).text.unicode_normalize

      max_message_length = (CHAT_WIDTH / CHAT_FONT_SIZE_X) - 1

      line_breaks = [-1]
      line_index = 0
      last_linebreak_pos = 0
      is_chat_rtl = is_rtl(chat)
      rtl_text_x_offset = is_chat_rtl ? CHAT_WIDTH : 0
      text_anchor = is_chat_rtl ? 'end' : 'start'

      chat_length = chat.length - 1
      (0..chat_length).each do |chat_index|
        last_linebreak_pos = chat_index if chat[chat_index] == ' '

        if line_index >= max_message_length
          last_linebreak_pos = chat_index if last_linebreak_pos <= chat_index - max_message_length

          line_breaks << last_linebreak_pos

          line_index = chat_index - last_linebreak_pos - 1
        end

        line_index += 1
      end

      line_wraps = []
      line_breaks.each_cons(2) do |(a, b)|
        line_wraps << [a + 1, b]
      end

      line_wraps << [line_breaks.last + 1, chat_length]

      # Message height equals the line break amount + the line for the name / time + the empty line afterwards
      message_height = (line_wraps.size + 2) * CHAT_FONT_SIZE

      # Add message to a new column if it goes over the canvas height
      if svg_y + message_height > CHAT_CANVAS_HEIGHT

        # Insert duplicate messages when going to next column for a seamless transition
        duplicate_y = CHAT_HEIGHT
        duplicates.each do |header, duplicate_content, duplicate_x|
          break if header.nil? || duplicate_y.negative?

          duplicate_x += CHAT_WIDTH

          duplicate_content.each do |content|
            duplicate_y -= CHAT_FONT_SIZE
            builder.text(x: duplicate_x + rtl_text_x_offset, y: duplicate_y, 'text-anchor' => text_anchor) { builder << content }
          end

          duplicate_y -= CHAT_FONT_SIZE
          builder.text(x: duplicate_x, y: duplicate_y, 'font-weight' => 'bold') { builder << header }
          duplicate_y -= CHAT_FONT_SIZE
        end

        # Set coordinates to new column
        svg_y = CHAT_STARTING_OFFSET
        svg_x += CHAT_WIDTH

        chat_x += CHAT_WIDTH
        chat_y = message_height
      else
        chat_y += message_height
      end

      overlay_position << [timestamp, chat_x, chat_y]

      # Username and chat timestamp
      header = "#{name}    #{Time.at(timestamp.to_f.round(0)).utc.strftime('%H:%M:%S')}"

      builder.text(x: svg_x, y: svg_y, 'font-weight' => 'bold') do
        builder << header
      end

      svg_y += CHAT_FONT_SIZE
      duplicate_content = []

      # Message text
      line_wraps.each do |a, b|
        safe_message = Loofah.fragment(chat[a..b]).scrub!(:escape)

        builder.text(x: svg_x + rtl_text_x_offset, y: svg_y, 'text-anchor' => text_anchor) { builder << safe_message }
        svg_y += CHAT_FONT_SIZE

        duplicate_content.unshift(safe_message)
      end

      duplicates.unshift([header, duplicate_content, svg_x])
      duplicates.pop
      svg_y += CHAT_FONT_SIZE
    end
  end

  # Dynamically adjust the chat canvas size for the fastest possible export
  cropped_chat_canvas_width = svg_x + CHAT_WIDTH
  cropped_chat_canvas_height = cropped_chat_canvas_width == CHAT_WIDTH ? svg_y : CHAT_CANVAS_HEIGHT

  builder = Nokogiri::XML(builder.target!)

  builder_root = builder.root
  builder_root.set_attribute('width', cropped_chat_canvas_width)
  builder_root.set_attribute('height', cropped_chat_canvas_height)

  # Saves chat as SVG / SVGZ file
  File.open("#{@published_files}/chats/chat.svg", 'w', TEMPORARY_FILES_PERMISSION) do |file|
    file.write(builder)
  end

  File.open("#{@published_files}/timestamps/chat_timestamps", 'w', TEMPORARY_FILES_PERMISSION) do |file|
    overlay_position.each do |timestamp, x, y|
      file.puts "#{timestamp} crop@c x #{x}, crop@c y #{y};"
    end
  end
end

def render_cursor(panzooms, cursor_reader)
  # Create the mouse pointer SVG
  builder = Builder::XmlMarkup.new

  # Add 'xmlns' => 'http://www.w3.org/2000/svg' for visual debugging, remove for faster exports
  builder.svg(width: CURSOR_RADIUS * 2, height: CURSOR_RADIUS * 2) do
    builder.circle(cx: CURSOR_RADIUS, cy: CURSOR_RADIUS, r: CURSOR_RADIUS, fill: 'red')
  end

  File.open("#{@published_files}/cursor/cursor.svg", 'w', TEMPORARY_FILES_PERMISSION) do |svg|
    svg.write(builder.target!)
  end

  cursor = []
  timestamps = []
  view_box = ''

  cursor_reader.each do |node|
    node_name = node.name
    next unless node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT

    timestamps << node.attribute('timestamp').to_f if node_name == 'event'

    cursor << node.inner_xml if node_name == 'cursor'
  end

  panzoom_index = 0
  File.open("#{@published_files}/timestamps/cursor_timestamps", 'w', TEMPORARY_FILES_PERMISSION) do |file|
    timestamps.each.with_index do |timestamp, frame_number|
      panzoom = panzooms[panzoom_index]

      if panzoom_index < panzooms.length && timestamp >= panzoom.first
        _, view_box = panzoom
        panzoom_index += 1
        view_box = view_box.split
      end

      # Get cursor coordinates
      pointer = cursor[frame_number].split

      width = view_box[2].to_f
      height = view_box[3].to_f

      # Calculate original cursor coordinates
      cursor_x = pointer[0].to_f * width
      cursor_y = pointer[1].to_f * height

      # Scaling required to reach target dimensions
      x_scale = SLIDES_WIDTH / width
      y_scale = SLIDES_HEIGHT / height

      # Keep aspect ratio
      scale_factor = [x_scale, y_scale].min

      # Scale
      cursor_x *= scale_factor
      cursor_y *= scale_factor

      # Translate given difference to new on-screen dimensions
      x_offset = (SLIDES_WIDTH - (scale_factor * width)) / 2
      y_offset = (SLIDES_HEIGHT - (scale_factor * height)) / 2

      # Center cursor
      cursor_x -= CURSOR_RADIUS
      cursor_y -= CURSOR_RADIUS

      cursor_x += x_offset
      cursor_y += y_offset

      # Move whiteboard to the right, making space for the chat and webcams
      cursor_x += WEBCAMS_WIDTH

      # Writes the timestamp and position down
      file.puts "#{timestamp} overlay@m x #{cursor_x.round(3)}, overlay@m y #{cursor_y.round(3)};"
    end
  end
end

def filter_complex_round(input, radius, output, default_alpha=255)
  return                                                                                  \
    "[#{input}]"                                                                          \
    "format=yuva420p,"                                                                    \
    "geq="                                                                                \
      "lum='p(X,Y)':"                                                                     \
      "a='if("                                                                            \
        "gt(abs(W/2-X),W/2-#{radius})*gt(abs(H/2-Y),H/2-#{radius}),"                      \
        "if("                                                                             \
          "lte(hypot(#{radius}-(W/2-abs(W/2-X)),#{radius}-(H/2-abs(H/2-Y))),#{radius}),"  \
          "#{default_alpha},"                                                             \
          "0"                                                                             \
        "),"                                                                              \
        "#{default_alpha}"                                                                \
      ")'"                                                                                \
    "[#{output}];"
end

def render_video(duration, meeting_name)
  # Determine if video had screensharing / chat messages
  deskshare = !HIDE_DESKSHARE && File.file?("#{@published_files}/deskshare/deskshare.#{VIDEO_EXTENSION}")
  chat = !HIDE_CHAT && File.file?("#{@published_files}/chats/chat.svg")

  render = "ffmpeg "

  render << "-stream_loop -1 -i /var/avistopia/resources/default-bg.mp4 "
  last_input_num = 0
  bg_input_num = last_input_num

  render << "-f concat -safe 0 #{BASE_URI} -i #{@published_files}/timestamps/whiteboard_timestamps "
  last_input_num += 1
  whiteboard_timestamps_input_num = last_input_num

  render << "-framerate 10 -loop 1 -i #{@published_files}/cursor/cursor.svg "
  last_input_num += 1
  cursor_input_num = last_input_num

  render << "-i #{@published_files}/video/webcams.#{VIDEO_EXTENSION} "
  last_input_num += 1
  webcams_input_num = last_input_num

  if deskshare
    render << "-i #{@published_files}/deskshare/deskshare.#{VIDEO_EXTENSION} "
    last_input_num += 1
    deskshare_input_num = last_input_num
  end

  if chat
    render << "-f lavfi -i color=c=#{CHAT_BG_COLOR}:size=#{CHAT_OUTER_WIDTH}x#{CHAT_OUTER_HEIGHT} "
    last_input_num += 1
    chat_bg_input_num = last_input_num
    render << "-framerate 1 -loop 1 -i #{@published_files}/chats/chat.svg "
    last_input_num += 1
    chat_input_num = last_input_num
  end

  # beginning of filter_complex
  render << \
    "-filter_complex \"" \
    "[#{cursor_input_num}]sendcmd=f=#{@published_files}/timestamps/cursor_timestamps[cursor];" \
    "[#{webcams_input_num}]scale=w=#{WEBCAMS_WIDTH}:h=#{WEBCAMS_HEIGHT}[webcams__not_rounded];" \
    + filter_complex_round("webcams__not_rounded", BORDER_RADIUS, "webcams")

  if deskshare
    render << \
      "[#{deskshare_input_num}]scale=w=#{SLIDES_WIDTH}:h=#{SLIDES_HEIGHT}:force_original_aspect_ratio=1[deskshare];" \
      "[deskshare][#{whiteboard_timestamps_input_num}]overlay[maincomponent];"
  else
    render << "[#{whiteboard_timestamps_input_num}]overlay[maincomponent];"
  end

  render << \
    "[maincomponent][cursor]overlay@m[maincomponent_cursor__not_rounded];" \
    + filter_complex_round("maincomponent_cursor__not_rounded", BORDER_RADIUS, "maincomponent_cursor") + \
    "[#{bg_input_num}][maincomponent_cursor]overlay=x=#{SLIDES_X}:y=#{SLIDES_Y}[bg_maincomponent_cursor];"
  last_stream_name = 'bg_maincomponent_cursor'

  if chat
    render << \
      "[#{chat_input_num}]sendcmd=f=#{@published_files}/timestamps/chat_timestamps," \
      "crop@c=w=#{CHAT_WIDTH}:h=#{CHAT_HEIGHT}:x=0:y=0[chat__no_bg];" \
      + filter_complex_round(chat_bg_input_num, BORDER_RADIUS, "chat_bg", 153) + \
      "[chat_bg][chat__no_bg]overlay=x=#{CHAT_X}:y=#{CHAT_Y}[chat];" \
      "[bg_maincomponent_cursor][chat]overlay=x=#{CHAT_OUTER_X}:y=#{CHAT_OUTER_Y}[bg_maincomponent_cursor_chat];"
    last_stream_name = 'bg_maincomponent_cursor_chat'
  end
  render << "[#{last_stream_name}][webcams]overlay=x=#{WEBCAMS_X}:y=#{WEBCAMS_Y}\" "
  # end of filter_complex

  render << \
    "-c:a aac -crf #{CONSTANT_RATE_FACTOR} -shortest -y -t #{duration} -threads #{THREADS} " \
    "-map #{webcams_input_num}:a " \
    "-metadata title=#{Shellwords.escape("#{meeting_name}")} #{BENCHMARK} #{@published_files}/meeting-tmp.mp4"

  success, = run_command(render)
  unless success
    warn('An error occurred rendering the video.')
    exit(false)
  end
end

def render_whiteboard(panzooms, slides, shapes, timestamps)
  shapes_interval_tree = IntervalTree::Tree.new(shapes)

  # Create frame intervals with starting time 0
  intervals = timestamps.uniq.sort
  intervals = intervals.drop(1) if intervals.first == -1

  frame_number = 0

  # Render the visible frame for each interval
  File.open("#{@published_files}/timestamps/whiteboard_timestamps", 'w', TEMPORARY_FILES_PERMISSION) do |file|
    slide_number = 0
    slide = slides[slide_number]
    view_box = ''

    intervals.each_cons(2).each do |interval_start, interval_end|
      # Get view_box parameter of the current slide
      _, view_box = panzooms.shift if !panzooms.empty? && interval_start >= panzooms.first.first

      if slide_number < slides.size && interval_start >= slides[slide_number].begin
        slide = slides[slide_number]
        slide_number += 1
      end

      draw = shapes_interval_tree.search(interval_start, unique: false, sort: false)

      draw = [] if draw.nil?
      draw = remove_adjacent(draw) if REMOVE_REDUNDANT_SHAPES && !draw.empty?

      svg_export(draw, view_box, slide.href, slide.width, slide.height, frame_number)

      # Write the frame's duration down
      file.puts "file ../frames/frame#{frame_number}.#{SVG_EXTENSION}"
      file.puts "duration #{(interval_end - interval_start).round(1)}"

      frame_number += 1
    end

    # The last image needs to be specified twice, without specifying the duration (FFmpeg quirk)
    file.puts "file ../frames/frame#{frame_number - 1}.#{SVG_EXTENSION}" if frame_number.positive?
  end
end

def svg_export(draw, view_box, slide_href, width, height, frame_number)
  # Builds SVG frame
  builder = Builder::XmlMarkup.new

  _view_box_x, _view_box_y, view_box_width, view_box_height = view_box.split.map(&:to_f)
  view_box_aspect_ratio = view_box_width / view_box_height

  width = width.to_f
  height = height.to_f
  slide_aspect_ratio = width / height

  outer_viewbox_x = 0
  outer_viewbox_y = 0
  outer_viewbox_width = SLIDES_WIDTH
  outer_viewbox_height = SLIDES_HEIGHT

  if view_box_aspect_ratio > slide_aspect_ratio
    outer_viewbox_height = SLIDES_WIDTH / view_box_aspect_ratio
  else
    outer_viewbox_width = SLIDES_HEIGHT * view_box_aspect_ratio
  end
  outer_viewbox = "#{outer_viewbox_x} #{outer_viewbox_y} #{outer_viewbox_width} #{outer_viewbox_height}"

  builder.svg(width: SLIDES_WIDTH, height: SLIDES_HEIGHT, viewBox: outer_viewbox,
              'xmlns:xlink' => 'http://www.w3.org/1999/xlink', 'xmlns' => 'http://www.w3.org/2000/svg') do
    # FFmpeg requires the xmlns:xmlink namespace. Add 'xmlns' => 'http://www.w3.org/2000/svg' for visual debugging
    builder.svg(viewBox: view_box,
                'xmlns:xlink' => 'http://www.w3.org/1999/xlink', 'xmlns' => 'http://www.w3.org/2000/svg') do
      # Display background image
      builder.image('xlink:href': slide_href, width: width, height: height)

      # Adds annotations
      draw.each do |shape|
        builder << shape.value
      end
    end
  end

  File.open("#{@published_files}/frames/frame#{frame_number}.#{SVG_EXTENSION}", 'w',
              TEMPORARY_FILES_PERMISSION) do |svg|
    if SVGZ_COMPRESSION
      svgz = Zlib::GzipWriter.new(svg, Zlib::BEST_SPEED)
      svgz.write(builder.target!)
      svgz.close
    else
      svg.write(builder.target!)
    end
  end
end

def export_presentation
  # Benchmark
  start = Time.now

  # Convert whiteboard assets to a format compatible with FFmpeg
  convert_whiteboard_shapes(Nokogiri::XML(File.open("#{@published_files}/shapes.svg")).remove_namespaces!)

  metadata = Nokogiri::XML(File.open("#{@published_files}/metadata.xml"))

  # Playback duration in seconds
  duration = metadata.xpath('recording/playback/duration').inner_text.to_f / 1000
  meeting_name = metadata.xpath('recording/meta/meetingName').inner_text

  shapes, slides, timestamps =
    parse_whiteboard_shapes(Nokogiri::XML::Reader(File.read("#{@published_files}/shapes_modified.svg")))
  panzooms, timestamps = parse_panzooms(Nokogiri::XML::Reader(File.read("#{@published_files}/panzooms.xml")),
                                        timestamps)

  # Ensure correct recording length - shapes.svg may have incorrect slides after recording ends
  timestamps << duration
  timestamps = timestamps.select { |t| t <= duration }

  # Create video assets
  render_chat(Nokogiri::XML::Reader(File.open("#{@published_files}/slides_new.xml"))) unless HIDE_CHAT
  render_cursor(panzooms, Nokogiri::XML::Reader(File.open("#{@published_files}/cursor.xml")))
  render_whiteboard(panzooms, slides, shapes, timestamps)

  BigBlueButton.logger.info("Finished composing presentation. Time: #{Time.now - start}")

  start = Time.now
  BigBlueButton.logger.info('Starting to export video')

  render_video(duration, meeting_name)
  add_chapters(duration, slides)
  add_captions if CAPTION_SUPPORT

  FileUtils.mv("#{@published_files}/meeting-tmp.mp4", "#{@published_files}/meeting.mp4")
  BigBlueButton.logger.info("Exported recording available at #{@published_files}/meeting.mp4. Rendering took: #{Time.now - start}")

  add_greenlight_buttons(metadata)
end

export_presentation

# Delete the contents of the scratch directories
FileUtils.rm_rf(["#{@published_files}/chats", "#{@published_files}/cursor", "#{@published_files}/frames",
                 "#{@published_files}/timestamps", "#{@published_files}/shapes_modified.svg",
                 "#{@published_files}/meeting_metadata"])

exit(0)
