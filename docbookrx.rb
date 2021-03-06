# docbookrx - A script to convert DocBook to AsciiDoc

require 'nokogiri'

infile = ARGV.first || 'sample.xml'

unless infile
  warn 'Please specify a DocBook file to convert'
  exit
end

docbook = File.read infile

class DocBookVisitor
  # transfer node type constants from Nokogiri
  Nokogiri::XML::Node.constants.each do |c|
    const_set c, (Nokogiri::XML::Node.const_get c) if c.to_s.end_with? '_NODE'
  end

  IndentationRx = /^[[:blank:]]+/
  LeadingSpaceRx = /\A\s/
  LeadingEndlinesRx = /\A\n+/
  TrailingEndlinesRx = /\n+\z/
  FirstLineIndentRx = /\A[[:blank:]]*/
  WrappedIndentRx = /\n[[:blank:]]*/

  EOL = "\n"

  ENTITY_TABLE = {
     169 => '(C)',
     174 => '(R)',
    8201 => ' ',
    8212 => '--',
    8216 => '`',
    8217 => '\'',
    8220 => '``',
    8221 => '\'\'',
    8230 => '...',
    8482 => '(TM)',
    8592 => '<-',
    8594 => '->',
    8656 => '<=',
    8658 => '=>'
  }

  REPLACEMENT_TABLE = {
    ':: ' => '{two-colons} '
  }

  PARA_TAG_NAMES = ['para', 'simpara']

  #COMPLEX_PARA_TAG_NAMES = ['formalpara', 'para']

  ADMONITION_NAMES = ['note', 'tip', 'warning', 'caution', 'important']

  SPECIAL_SECTION_NAMES = ['abstract', 'appendix', 'bibliography', 'glossary', 'preface']

  LITERAL_NAMES = ['application', 'classname', 'command', 'constant', 'envar', 'interfacename', 'methodname', 'varname']

  LITERAL_UNNAMED = ['application', 'command']

  PATH_NAMES = ['directory', 'filename']

  UI_NAMES = ['guibutton', 'guimenu', 'guilabel', 'keycap']

  attr_reader :lines

  def initialize opts = {}
    @lines = []
    @level = 1
    @skip = {}
    @requires_index = false
    @list_index = 0
    @continuation = false
    @adjoin_next = false
    @idprefix = opts[:idprefix] || '_'
    @idseparator = opts[:idseparator] || '_'
    @normalize_ids = opts.fetch :normalize_ids, true
    @em_char = opts[:em_char] || '_'
    @attributes = opts[:attributes] || {}
    @runin_admonition_label = opts.fetch :runin_admonition_label, true
    @sentence_per_line = opts.fetch :sentence_per_line, true
    @preserve_line_wrap = if @sentence_per_line
      false
    else
      opts.fetch :preserve_line_wrap, true
    end
    @delimit_source = opts.fetch :delimit_source, true
  end

  ## Traversal methods

  # Main processor loop
  def visit node
    return if node.type == COMMENT_NODE
    return if node.instance_variable_get :@skip

    before_traverse if (at_root = (node == node.document.root)) && (respond_to? :before_traverse)

    name = node.name
    visit_method_name = case node.type
    when PI_NODE
      :visit_pi
    when ENTITY_REF_NODE
      :visit_entity_ref
    else
      if ADMONITION_NAMES.include? name
        :process_admonition
      elsif LITERAL_NAMES.include? name
        :process_literal
      elsif PATH_NAMES.include? name
        :process_path
      elsif UI_NAMES.include? name
        :process_ui
      elsif SPECIAL_SECTION_NAMES.include? name
        :process_special_section
      else
        %(visit_#{name}).to_sym
      end
    end

    result = if respond_to? visit_method_name
      send visit_method_name, node
    elsif respond_to? :default_visit
      send :default_visit, node
    end

    traverse_children node if result == true
    after_traverse if at_root && (respond_to? :after_traverse)
  end

  def traverse_children node, opts = {}
    (opts[:using_elements] ? node.elements : node.children).each do |child|
      child.accept self
    end
  end
  alias :proceed :traverse_children

  ## Text extraction and processing methods

  def text node, unsub = true
    if node
      if node.is_a? Nokogiri::XML::Node
        unsub ? reverse_subs(node.text) : node.text
      elsif node.is_a? Nokogiri::XML::NodeSet && (first = node.first)
        unsub ? reverse_subs(first.text) : first.text
      else
        nil
      end
    else
      nil
    end
  end

  def text_at_css node, css, unsub = true
    text (node.at_css css, unsub)
  end

  def format_text node
    if node && (node.is_a? Nokogiri::XML::NodeSet)
      node = node.first
    end

    if node.is_a? Nokogiri::XML::Node
      append_blank_line
      proceed node
      @lines.pop
    else
      nil
    end
  end

  def format_text_at_css node, css
    format_text (node.at_css css)
  end

  def entity number
    [number].pack 'U*'
  end

  # Replaces XML entities, and other encoded forms that AsciiDoc automatically
  # applies, with their plain-text equivalents.
  #
  # This method effectively undoes the inline substitutions that AsciiDoc performs.
  #
  # str - The String to processes
  #
  # Examples
  #
  #   reverse_subs "&#169; Acme, Inc."
  #   # => "(C) Acme, Inc."
  #
  # Returns The processed String
  def reverse_subs str
    ENTITY_TABLE.each do |num, text|
      str = str.gsub((entity num), text)
    end
    REPLACEMENT_TABLE.each do |original, replacement|
      str = str.gsub original, replacement
    end
    str
  end

  ## Writer methods

  def append_line line, unsub = false
    line = reverse_subs line if unsub
    @lines << line
  end

  def append_blank_line
    if @continuation
      @continuation = false
    elsif @adjoin_next
      @adjoin_next = false
    else
      @lines << ''
    end
  end
  alias :start_new_line :append_blank_line

  def append_block_title node, prefix = nil
    if (title = (format_text_at_css node, '> title'))
      leading_char = '.'
      # special case for <itemizedlist role="see-also-list"><title>:
      # omit the prefix '.' as we want simple text on a bullet, not a heading
      if node.parent.name == 'itemizedlist' && ((node.attr 'role') == 'see-also-list')
        leading_char = nil
      end
      append_line %(#{leading_char}#{prefix}#{unwrap_text title})
      @adjoin_next = true
      true
    else
      false
    end
  end

  def append_block_role node
    if (role = node.attr('role'))
      append_line %([.#{role}])
      #@adjoin_next = true
      true
    else
      false
    end
  end

  def append_text text, unsub = false
    text = reverse_subs text if unsub
    @lines[-1] = %(#{@lines[-1]}#{text})
  end

  ## Lifecycle callbacks

  #def before_traverse
  #end

  def after_traverse
    if @requires_index
      append_blank_line
      append_line 'ifdef::backend-docbook[]'
      append_line '[index]'
      append_line '== Index'
      append_line '// Generated automatically by the DocBook toolchain.'
      append_line 'endif::backend-docbook[]'
    end
  end

  ## Node visitor callbacks

 def default_visit node
    warn %(No visitor defined for <#{node.name}>! Skipping.)
    false
  end

  # pass thru XML entities unchanged, eg., for &rarr;
  def visit_entity_ref node
    append_text %(#{node})
    false
  end

  # Skip title as it's always handled by the parent visitor
  def visit_title node
    false
  end

  def visit_toc node
    false
  end

  ### Document node (article | book | chapter) & header node (articleinfo | bookinfo | info) visitors

  def visit_book node
    process_doc node
  end

  def visit_article node
    process_doc node
  end

  def visit_info node
    process_info node
  end
  alias :visit_bookinfo :visit_info
  alias :visit_articleinfo :visit_info

  def visit_chapter node
    # treat document with <chapter> root element as books
    if node == node.document.root
      @adjoin_next = true
      process_section node do
        append_line ':doctype: book'
        append_line ':numbered:'
        append_line ':toc: left'
        append_line ':icons: font'
        append_line ':experimental:'
        append_line %(:idprefix: #{@idprefix}).rstrip unless @idprefix == '_'
        append_line %(:idseparator: #{@idseparator}).rstrip unless @idseparator == '_'
        @attributes.each do |name, val|
          append_line %(:#{name}: #{val}).rstrip
        end
      end
    else
      process_section node
    end
  end

  def process_doc node
    @level += 1
    proceed node, :using_elements => true
    @level -= 1
    false
  end

  def process_info node
    title = text_at_css node, '> title'
    append_line %(= #{title})
    authors = []
    (node.css 'author').each do |author_node|
      # FIXME need to detect DocBook 4.5 vs 5.0 to handle names properly
      author = if (personname_node = (author_node.at_css 'personname'))
        text personname_node
      else
        [(text_at_css author_node, 'firstname'), (text_at_css author_node, 'surname')].compact * ' '
      end
      if (email_node = (author_node.at_css 'email'))
        author = %(#{author} <#{text email_node}>)
      end
      authors << author unless author.empty?
    end
    append_line (authors * '; ') unless authors.empty?
    date_line = nil
    if (revnumber_node = node.at_css('revhistory revnumber', 'releaseinfo'))
      date_line = %(v#{revnumber_node.text}, ) 
    end
    if (date_node = node.at_css('> date', '> pubdate'))
      append_line %(#{date_line}#{date_node.text})
    end
    if node.name == 'bookinfo' || node.parent.name == 'book' || node.parent.name == 'chapter'
      append_line ':doctype: book'
      append_line ':numbered:'
      append_line ':toc: left'
      append_line ':icons: font'
      append_line ':experimental:'
    end
    append_line %(:idprefix: #{@idprefix}).rstrip unless @idprefix == '_'
    append_line %(:idseparator: #{@idseparator}).rstrip unless @idseparator == '_'
    @attributes.each do |name, val|
      append_line %(:#{name}: #{val}).rstrip
    end
    false
  end

  # Very rough first pass at processing xi:include
  def visit_include node
    # QUESTION should we reuse this instance to traverse the new tree?
    include_infile = node.attr 'href'
    include_outfile = include_infile.sub '.xml', '.adoc'
    if File.readable? include_infile
      doc = Nokogiri::XML::Document.parse(File.read include_infile)
      # TODO pass in options that were passed to this visitor
      visitor = self.class.new
      doc.root.accept visitor
      result = visitor.lines
      result.shift while result.size > 0 && result.first.empty?
      File.open(include_outfile, 'w') {|f| f.write(visitor.lines * EOL) }
    else
      warn %(Include file not readable: #{include_infile})
    end
    append_blank_line
    # TODO make leveloffset more context-aware
    append_line %(:leveloffset: #{@level - 1}) if @level > 1
    append_line %(include::#{include_outfile}[])
    append_line %(:leveloffset: 0) if @level > 1
    false
  end

  ### Section node (part | section | chapter | %special%) visitors

  def visit_section node
    process_section node
  end

  def visit_simplesect node
    process_section node
  end

  def visit_bridgehead node
    level = node.attr('renderas').sub('sect', '').to_i + 1
    append_blank_line
    append_line '[float]'
    title = format_text node
    if (id = (resolve_id node, normalize: @normalize_ids)) && id != (generate_id title)
      append_line %([[#{id}]])
    end
    append_line %(#{'=' * level} #{unwrap_text title})
    false
  end

  def process_special_section node
    process_section node, node.name
  end

  def process_section node, special = nil
    append_blank_line
    if special
      append_line ':numbered!:'
      append_blank_line
      append_line %([#{special}])
    end
    title = if (title_node = (node.at_css '> title') || (node.at_css '> info > title'))
      format_text title_node
    else
      warn %(No title found for section node: #{node})
      'Unknown Title!'
    end
    if (id = (resolve_id node, normalize: @normalize_ids)) && id != (generate_id title)
      append_line %([[#{id}]])
    end
    append_line %(#{'=' * @level} #{unwrap_text title})
    yield if block_given?
    @level += 1
    proceed node, :using_elements => true
    @level -= 1
    if special
      append_blank_line
      append_line ':numbered:'
    end
    false
  end

  def generate_id title
    sep = @idseparator
    pre = @idprefix
    # FIXME move regexp to constant
    illegal_sectid_chars = /&(?:[[:alpha:]]+|#[[:digit:]]+|#x[[:alnum:]]+);|\W+?/
    id = %(#{pre}#{title.downcase.gsub(illegal_sectid_chars, sep).tr_s(sep, sep).chomp(sep)})
    if pre.empty? && id.start_with?(sep)
      id = id[1..-1]
      id = id[1..-1] while id.start_with?(sep)
    end
    id
  end

  def resolve_id node, opts = {}
    if (id = node['id'] || node['xml:id'])
      opts[:normalize] ? (normalize_id id) : id
    else
      nil
    end
  end

  # Lowercase id and replace underscores or hyphens with the @idseparator
  # TODO ensure id adheres to @idprefix
  def normalize_id id
    if id
      normalized_id = id.downcase.tr('_-', @idseparator)
      normalized_id = %(#{@idprefix}#{normalized_id}) if @idprefix && !(normalized_id.start_with? @idprefix)
      normalized_id
    else
      nil
    end
  end

  ### Block node visitors

  def visit_formalpara node
    append_blank_line
    append_block_title node
    true
  end

  def visit_para node
    append_blank_line
    append_block_role node
    append_blank_line
    true
  end

  def visit_simpara node
    append_blank_line
    append_block_role node
    append_blank_line
    true
  end

  def process_admonition node
    name = node.name
    label = name.upcase
    elements = node.elements
    append_blank_line
    append_block_title node
    if elements.size == 1 && (PARA_TAG_NAMES.include? (child = elements.first).name)
      if @runin_admonition_label
        append_line %(#{label}: #{format_text child})
      else
        append_line %([#{label}])
        append_line (format_text child)
      end
    else
      append_line %([#{label}])
      append_line '===='
      @adjoin_next = true
      proceed node
      @adjoin_next = false
      append_line '===='
    end
    false
  end

  def visit_itemizedlist node
    append_blank_line
    append_block_title node
    true
  end

  def visit_procedure node
    append_blank_line
    append_block_title node, 'Procedure: '
    visit_orderedlist node
  end

  def visit_substeps node
    visit_orderedlist node
  end

  def visit_stepalternatives node
    visit_orderedlist node
  end

 def visit_orderedlist node
    @list_index = 1
    append_blank_line
    # TODO no title?
    if (numeration = (node.attr 'numeration')) && numeration != 'arabic'
      append_line %([#{numeration}])
    end
    true
  end

  def visit_variablelist node
    append_blank_line
    append_block_title node
    @lines.pop if @lines[-1].empty?
    true
  end

  def visit_step node
    visit_listitem node
  end

  # FIXME this method needs cleanup, remove hardcoded logic!
  def visit_listitem node
    elements = node.elements.to_a
    item_text = format_text elements.shift
    
    # do we want variable depths of bullets?
    depth = (node.ancestors.length - 4)
    # or static bullet depths
    depth = 1

    marker = (node.parent.name == 'orderedlist' || node.parent.name == 'procedure' ? '.' * depth : 
      (node.parent.name == 'stepalternatives' ? 'a.' : '*' * depth))
    placed_bullet = false
    item_text.split(EOL).each_with_index do |line, i|
      line = line.gsub IndentationRx, ''
      if line.length > 0
        if line == '====' # ???
          append_line %(#{line})
        elsif !placed_bullet
          append_line %(#{marker} #{line})
          placed_bullet = true
        else
          append_line %(  #{line})
        end
      end
    end

    unless elements.empty?
      elements.each_with_index do |child, i|
        unless i == 0 && child.name == 'literallayout'
          append_line '+'
          @continuation = true
        end
        child.accept self
      end
      append_blank_line
    end
    false
  end

  def visit_varlistentry node
    # FIXME adds an extra blank line before first item
    append_blank_line unless (previous = node.previous_element) && previous.name == 'title'
    append_line %(#{format_text(node.at_css node, '> term')}::)
    item_text = format_text(node.at_css node, '> listitem > para', '> listitem > simpara')
    if item_text
      item_text.split(EOL).each do |line|
        append_line %(  #{line})
      end
    end

    # support listitem figures in a listentry
    # FIXME we should be supporting arbitrary complex content!
    if node.at_css('listitem figure')
      # warn %(#{node.at_css('listitem figure')})
      visit_figure node.at_css('listitem figure')
    end

    # FIXME this doesn't catch complex children
    false
  end

  def visit_glossentry node
    append_blank_line
    if !(previous = node.previous_element) || previous.name != 'glossentry'
      append_line '[glossary]'
    end
    true
  end

  def visit_glossterm node
    append_line %(#{format_text node}::)
    false
  end

  def visit_glossdef node
    append_line %(  #{text node.elements.first})
    false
  end

  def visit_bibliodiv node
    append_blank_line
    append_line '[bibliography]'
    true
  end

  def visit_bibliomisc node
    true
  end

  def visit_bibliomixed node
    append_blank_line
    proceed node
    append_line @lines.pop.sub(/^\[(.*?)\]/, '* [[[\\1]]]')
    false
  end

  def visit_literallayout node
    append_blank_line
    source_lines = node.text.rstrip.split EOL
    if (source_lines.detect{|line| line.rstrip.empty?})
      append_line '....'
      append_line node.text.rstrip
      append_line '....'
    else
      source_lines.each do |line|
        append_line %(  #{line})
      end
    end
    false
  end

  def visit_screen node
    append_blank_line unless node.parent.name == 'para'
    source_lines = node.text.rstrip.split EOL
    if source_lines.detect {|line| line.match(/^-{4,}/) }
      append_line '[listing]'
      append_line '....'
      append_line node.text.rstrip
      append_line '....'
    else
      append_line '----'
      append_line node.text.rstrip
      append_line '----'
    end
    false
  end

  def visit_programlisting node
    language = node.attr('language') || @attributes['language']
    language = %(,#{language.downcase}) if language
    linenums = node.attr('linenumbering') == 'numbered'
    append_blank_line unless node.parent.name == 'para'
    append_line %([source#{language}#{linenums ? ',linenums' : nil}])
    source_lines = node.text.rstrip.split EOL
    if @delimit_source || (source_lines.detect {|line| line.rstrip.empty?})
      append_line '----'
      append_line (source_lines * EOL)
      append_line '----'
    else
      append_line (source_lines * EOL)
    end
    false
  end

  def visit_example node
    process_example node
  end

  def visit_informalexample node
    process_example node
  end

  def process_example node
    append_blank_line
    append_block_title node
    elements = node.elements.to_a
    if elements.size > 0 && elements.first.name == 'title'
      elements.shift
    end
    if elements.size == 1 && (PARA_TAG_NAMES.include? (child = elements.first).name)
      append_line '[example]'
      # must reset adjoin_next in case block title is placed
      @adjoin_next = false
      append_line (format_text child)
    else
      append_line '===='
      @adjoin_next = true
      proceed node
      @adjoin_next = false
      append_line '===='
    end
    false
  end

  # FIXME wrap this up in a process_block method
  def visit_sidebar node
    append_blank_line
    append_block_title node 
    elements = node.elements.to_a
    # TODO make skipping title a part of append_block_title perhaps?
    if elements.size > 0 && elements.first.name == 'title'
      elements.shift
    end
    if elements.size == 1 && PARA_TAG_NAMES.include?((child = elements.first).name)
      append_line '[sidebar]'
      append_line format_text child
    else
      append_line '****'
      @adjoin_next = true
      proceed node
      @adjoin_next = false
      append_line '****'
    end
    false
  end

  def visit_blockquote node
    append_blank_line
    append_block_title node 
    elements = node.elements.to_a
    # TODO make skipping title a part of append_block_title perhaps?
    if elements.size > 0 && elements.first.name == 'title'
      elements.shift
    end
    if elements.size == 1 && PARA_TAG_NAMES.include?((child = elements.first).name)
      append_line '[quote]'
      append_line format_text child
    else
      append_line '____'
      @adjoin_next = true
      proceed node
      @adjoin_next = false
      append_line '____'
    end
    false
  end

  def visit_table node
    append_blank_line
    append_block_title node
    process_table node
    false
  end

  def visit_informaltable node
    append_blank_line
    process_table node
    false
  end

  def process_table node
    numcols = (node.at_css '> tgroup').attr('cols').to_i
    cols = ('1' * numcols).split('')
    body = node.at_css '> tgroup > tbody'
    row1 = body.at_css '> row'
    row1_cells = row1.elements
    numcols.times do |i|
      next if !(element = row1_cells[i].elements.first)
      case element.name
      when 'literallayout'
        cols[i] = %(#{cols[i]}*l)
      end
    end

    if (frame = node.attr('frame'))
      frame = %(, frame="#{frame}")
    else
      frame = nil
    end
    options = []
    if (head = node.at_css '> tgroup > thead')
      options << 'header'
    end
    if (foot = node.at_css '> tgroup > tfoot')
      options << 'footer'
    end
    options = (options.empty? ? nil : %(, options="#{options * ','}"))
    append_line %([cols="#{cols * ','}"#{frame}#{options}])
    append_line '|==='
    if head
      (head.css '> row > entry').each do |cell|
        append_line %(| #{text cell})
      end
    end
    (node.css '> tgroup > tbody > row').each do |row|
      append_blank_line
      row.elements.each do |cell|
        next if !(element = cell.elements.first)
        if element.text.empty?
          append_line '|'
        else
          append_line %(| #{text cell})
          #case element.name
          #when 'literallayout'
          #  append_line %(|`#{text cell}`)
          #else
          #  append_line %(|#{text cell})
          #end
        end
      end
    end
    if foot
      (foot.css '> row > entry').each do |cell|
        # FIXME needs inline formatting like body
        append_line %(| #{text cell})
      end
    end
    append_line '|==='
    false
  end

  ### Inline node visitors

  def visit_text node
    in_para = PARA_TAG_NAMES.include?(node.parent.name) || node.parent.name == 'phrase'
    is_first = !node.previous_element
    # drop text if empty unless we're processing a paragraph
    unless node.text.rstrip.empty? && !in_para
      text = node.text
      if in_para
        leading_space_match = text.match LeadingSpaceRx
        # strips surrounding endlines and indentation on normal paragraphs
        # TODO factor out this whitespace processing
        text = text.gsub(LeadingEndlinesRx, '')
            .gsub(WrappedIndentRx, @preserve_line_wrap ? EOL : ' ')
            .gsub(TrailingEndlinesRx, '')
        if is_first
          text = text.lstrip
        elsif leading_space_match && !!(text !~ LeadingSpaceRx)
          # QUESTION if leading space was an endline, should we restore the endline or just put a space char?
          text = %(#{leading_space_match[0]}#{text})
        end

        # FIXME sentence-per-line logic should be applied at paragraph block level only
        if @sentence_per_line
          # FIXME move regexp to constant
          text = text.gsub(/(?:^|\b)\.[[:blank:]]+(?!\Z)/, %(.\n))
        end
      end
      append_text text, true
    end
    false
  end

  def visit_anchor node
    return false if node.parent.name.start_with? 'biblio'
    id = resolve_id node, normalize: @normalize_ids
    append_text %([[#{id}]])
    false
  end

  # NOTE same as visit_xref, except element text is used as label
  def visit_link node
    linkend = node.attr 'linkend'
    label = format_text node
    id = @normalize_ids ? (normalize_id linkend) : linkend
    append_text %(<<#{id},#{lazy_quote label}>>)
    false
  end

  def visit_ulink node
    url = node.attr('url')
    prefix = 'link:'
    if url.start_with?('http://') || url.start_with?('https://')
      prefix = nil
    end
    label = text node
    if label.empty? || url == label
      if (ref = @attributes.key(url))
        url = %({#{ref}})
      end
      append_text %(#{prefix}#{url})
    else
      if (ref = @attributes.key(url))
        url = %({#{ref}})
      end
      append_text %(#{prefix}#{url}[#{label}])
    end
    false
  end

  def visit_xref node
    linkend = node.attr 'linkend'
    # FIXME delegate label formatting to a method
    label = linkend.gsub '_', ' '
    id = @normalize_ids ? (normalize_id linkend) : linkend
    append_text %(<<#{id},#{lazy_quote label}>>)
    false
  end

  def visit_phrase node
    if node.attr 'role'
      # FIXME for now, double up the marks to be sure we catch it
      append_text %([#{node.attr 'role'}]###{format_text node}##)
    else
      append_text %(#{format_text node})
    end
    false
  end

  def visit_emphasis node
    quote_char = node.attr('role') == 'strong' ? '*' : @em_char
    append_text %(#{quote_char}#{format_text node}#{quote_char})
    false
  end

  def visit_trademark node
    append_text %(#{format_text node}(TM))
    false
  end

  def visit_literal node
    process_literal node
  end

  def visit_code node
    process_literal node
  end

  def process_path node
    role = case (name = node.name)
    when 'filename'
      'path'
    when 'directory'
      'path'
    else
      name
    end
    append_text %([#{role}]_#{node.text}_)
    false
  end

  def process_ui node
    name = node.name
    if name == 'guilabel' && (next_node = node.next) &&
        next_node.type == ENTITY_REF_NODE && ['rarr', 'gt'].include?(next_node.name)
      name = 'guimenu'
    end

    case name
    when 'guimenu'
      append_text %(menu:#{node.text})
      items = []
      while (node = node.next) && ((node.type == ENTITY_REF_NODE && ['rarr', 'gt'].include?(node.name)) ||
        (node.type == ELEMENT_NODE && ['guimenu', 'guilabel'].include?(node.name)))
        if node.type == ELEMENT_NODE
          items << node.text
        end
        node.instance_variable_set :@skip, true
      end
      append_text %([#{items * ' > '}]) 
    when 'guibutton'
      append_text %(btn:[#{node.text}])
    when 'guilabel'
      append_text %([label]##{node.text}#)
    when 'keycap'
      append_text %(kbd:[#{node.text}])
    end
    false
  end

  def process_literal node
    name = node.name
    unless LITERAL_UNNAMED.include? name
      shortname = (name == 'envar' ? 'var' : (name.sub 'name', ''))
      append_text %([#{shortname}])
    end
    node_text = node.text
    if node_text == '`'
      append_text '+`+'
    # FIXME be smarter about when to use + vs `
    # FIXME know when to use ++
    #elsif node_text.include? '`'
    #  append_text %(+#{node_text}+)
    #else
    #  append_text %(`#{node_text}`)
    #end
    elsif node_text.include? '+'
      append_text %(`#{node_text}`)
    else
      append_text %(+#{node_text}+)
    end
    false 
  end

  def visit_inlinemediaobject node
    src = node.at_css('imageobject imagedata').attr('fileref')
    alt = text_at_css node, 'textobject phrase'
    generated_alt = File.basename(src)[0...-(File.extname(src).length)]
    alt = nil if alt && alt == generated_alt
    append_text %(image:#{src}[#{lazy_quote alt}])
    false
  end

  def visit_mediaobject node
    visit_figure node
  end

  # FIXME share logic w/ visit_inlinemediaobject, which is the same here except no block_title and uses append_text, not append_line
  def visit_figure node
    append_blank_line
    append_block_title node
    src = node.at_css('imageobject imagedata').attr('fileref')
    alt = text_at_css node, 'textobject phrase'

    generated_alt = File.basename(src)[0...-(File.extname(src).length)]
    alt = nil if alt && alt == generated_alt
    append_blank_line
    append_line %(image::#{src}[#{lazy_quote alt}])
    false
  end

  def visit_footnote node
    append_text %(footnote:[#{text_at_css node, '> para', '> simpara'}])
    # FIXME not sure a blank line is always appropriate
    #append_blank_line
    false
  end

  # FIXME blank lines showing up between adjacent index terms
  def visit_indexterm node
    previous_skipped = false
    if @skip.has_key? :indexterm
      skip_count = @skip[:indexterm]
      if skip_count > 0
        @skip[:indexterm] -= 1
        return false
      else
        @skip.delete :indexterm
        previous_skipped = true
      end
    end

    @requires_index = true
    entries = [(text_at_css node, 'primary'), (text_at_css node, 'secondary'), (text_at_css node, 'tertiary')].compact
    #if previous_skipped && (previous = node.previous_element) && previous.name == 'indexterm'
    #  append_blank_line
    #end
    @skip[:indexterm] = entries.size - 1 if entries.size > 1
    append_line %[(((#{entries * ','})))]
    # Only if next word matches the index term do we use double-bracket form
    #if entries.size == 1
    #  append_text %[((#{entries.first}))]
    #else
    #  @skip[:indexterm] = entries.size - 1
    #  append_text %[(((#{entries * ','})))]
    #end
    false
  end

  def visit_pi node
    case node.name
    when 'asciidoc-br'
      append_text ' +'
    when 'asciidoc-hr'
      # <?asciidoc-hr?> will be wrapped in a para/simpara
      append_text '\'' * 3
    end
    false
  end

  def lazy_quote text, seek = ','
    if text && (text.include? seek)
      %("#{text}")
    else
      text
    end
  end

  def unwrap_text text
    text.gsub WrappedIndentRx, ''
  end

end

doc = Nokogiri::XML::Document.parse(docbook)

options = {
#  runin_admonition_label: false,
#  sentence_per_line: false,
#  preserve_line_wrap: true,
#  idprefix: '',
#  idseparator: '-',
#  normalize_ids: false,
#  em_char: '\'',
#  attributes: {
#    'ref-contribute' => 'http://beanvalidation.org/contribute/',
#    'ref-jsr-317' => 'http://jcp.org/en/jsr/detail?id=317'
#  }
}

visitor = DocBookVisitor.new options
doc.root.accept visitor
puts visitor.lines * "\n"
