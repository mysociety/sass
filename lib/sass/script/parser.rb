require 'sass/script/lexer'

module Sass
  module Script
    # The parser for SassScript.
    # It parses a string of code into a tree of {Script::Node}s.
    class Parser
      # @param str [String, StringScanner] The source text to parse
      # @param line [Fixnum] The line on which the SassScript appears.
      #   Used for error reporting
      # @param offset [Fixnum] The number of characters in on which the SassScript appears.
      #   Used for error reporting
      # @param options [{Symbol => Object}] An options hash;
      #   see {file:SASS_REFERENCE.md#sass_options the Sass options documentation}
      def initialize(str, line, offset, options = {})
        @options = options
        @lexer = Lexer.new(str, line, offset, options)
      end

      # Parses a SassScript expression within an interpolated segment (`#{}`).
      # This means that it stops when it comes across an unmatched `}`,
      # which signals the end of an interpolated segment,
      # it returns rather than throwing an error.
      #
      # @return [Script::Node] The root node of the parse tree
      # @raise [Sass::SyntaxError] if the expression isn't valid SassScript
      def parse_interpolated
        expr = assert_expr :expr
        assert_tok :end_interpolation
        expr.options = @options
        expr
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @lexer.line, :filename => @options[:filename]
        raise e
      end

      # Parses a SassScript expression.
      #
      # @return [Script::Node] The root node of the parse tree
      # @raise [Sass::SyntaxError] if the expression isn't valid SassScript
      def parse
        expr = assert_expr :expr
        assert_done
        expr.options = @options
        expr
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @lexer.line, :filename => @options[:filename]
        raise e
      end

      # Parses a SassScript expression,
      # ending it when it encounters one of the given identifier tokens.
      #
      # @param [#include?(String)] A set of strings that delimit the expression.
      # @return [Script::Node] The root node of the parse tree
      # @raise [Sass::SyntaxError] if the expression isn't valid SassScript
      def parse_until(tokens)
        @stop_at = tokens
        expr = assert_expr :expr
        assert_done
        expr.options = @options
        expr
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @lexer.line, :filename => @options[:filename]
        raise e
      end

      # Parses the argument list for a mixin include.
      #
      # @return [Array<Script::Node>] The root nodes of the arguments.
      # @raise [Sass::SyntaxError] if the argument list isn't valid SassScript
      def parse_mixin_include_arglist
        args = []

        if try_tok(:lparen)
          args = arglist || args
          assert_tok(:rparen)
        end
        assert_done

        args.each {|a| a.options = @options}
        args
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @lexer.line, :filename => @options[:filename]
        raise e
      end

      # Parses the argument list for a mixin definition.
      #
      # @return [Array<Script::Node>] The root nodes of the arguments.
      # @raise [Sass::SyntaxError] if the argument list isn't valid SassScript
      def parse_mixin_definition_arglist
        args = []

        if try_tok(:lparen)
          args = defn_arglist(false) || args
          assert_tok(:rparen)
        end
        assert_done

        args.each do |k, v|
          k.options = @options
          v.options = @options if v
        end
        args
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @lexer.line, :filename => @options[:filename]
        raise e
      end

      # Parses a SassScript expression.
      #
      # @overload parse(str, line, offset, filename = nil)
      # @return [Script::Node] The root node of the parse tree
      # @see Parser#initialize
      # @see Parser#parse
      def self.parse(*args)
        new(*args).parse
      end

      # @private
      PRECEDENCE = [
        :comma, :concat, :or, :and,
        [:eq, :neq],
        [:gt, :gte, :lt, :lte],
        [:plus, :minus],
        [:times, :div, :mod],
      ]

      class << self
        # Returns an integer representing the precedence
        # of the given operator.
        # A lower integer indicates a looser binding.
        #
        # @private
        def precedence_of(op)
          PRECEDENCE.each_with_index do |e, i|
            return i if Array(e).include?(op)
          end
          raise "[BUG] Unknown operator #{op}"
        end

        private

        # Defines a simple left-associative production.
        # name is the name of the production,
        # sub is the name of the production beneath it,
        # and ops is a list of operators for this precedence level
        def production(name, sub, *ops)
          class_eval <<RUBY
            def #{name}
              return unless e = #{sub}
              while tok = try_tok(#{ops.map {|o| o.inspect}.join(', ')})
                e = Operation.new(e, assert_expr(#{sub.inspect}), tok.type)
              end
              e
            end
RUBY
        end

        def unary(op, sub)
          class_eval <<RUBY
            def unary_#{op}
              return #{sub} unless try_tok(:#{op})
              UnaryOperation.new(assert_expr(:unary_#{op}), :#{op})
            end
RUBY
        end
      end

      private

      production :expr, :concat, :comma

      def concat
        return unless e = or_expr
        while sub = or_expr
          e = Operation.new(e, sub, :concat)
        end
        e
      end

      production :or_expr, :and_expr, :or
      production :and_expr, :eq_or_neq, :and
      production :eq_or_neq, :relational, :eq, :neq
      production :relational, :plus_or_minus, :gt, :gte, :lt, :lte
      production :plus_or_minus, :times_div_or_mod, :plus, :minus
      production :times_div_or_mod, :unary_minus, :times, :div, :mod

      unary :minus, :unary_div
      unary :div, :unary_not # For strings, so /foo/bar works
      unary :not, :funcall

      def funcall
        return paren unless @lexer.peek && @lexer.peek.type == :ident
        return if @stop_at && @stop_at.include?(@lexer.peek.value)

        name = @lexer.next
        # An identifier without arguments is just a string
        unless try_tok(:lparen)
          if color = Color::HTML4_COLORS[name.value]
            return Color.new(color)
          end

          filename = @options[:filename]
          warn(<<END)
DEPRECATION WARNING:
On line #{name.line}, character #{name.offset}#{" of '#{filename}'" if filename}
Implicit strings have been deprecated and will be removed in version 3.0.
'#{name.value}' was not quoted. Please add double quotes (e.g. "#{name.value}").
END
          Script::String.new(name.value)
        else
          args = arglist || []
          assert_tok(:rparen)
          Script::Funcall.new(name.value, args)
        end
      end

      def defn_arglist(must_have_default)
        return unless c = try_tok(:const)
        var = Script::Variable.new(c.value)
        if try_tok(:single_eq)
          val = assert_expr(:concat)
        elsif must_have_default
          raise SyntaxError.new("Required argument #{var.inspect} must come before any optional arguments.")
        end

        return [[var, val]] unless try_tok(:comma)
        [[var, val], *defn_arglist(val)]
      end

      def arglist
        return unless e = concat
        return [e] unless try_tok(:comma)
        [e, *arglist]
      end

      def paren
        return variable unless try_tok(:lparen)
        e = assert_expr(:expr)
        assert_tok(:rparen)
        return e
      end

      def variable
        return string unless c = try_tok(:const)
        Variable.new(c.value)
      end

      def string
        return literal unless first = try_tok(:string)
        return first.value unless try_tok(:begin_interpolation)
        mid = parse_interpolated
        last = assert_expr(:string)
        Operation.new(first.value, Operation.new(mid, last, :plus), :plus)
      end

      def literal
        (t = try_tok(:number, :color, :bool)) && (return t.value)
      end

      # It would be possible to have unified #assert and #try methods,
      # but detecting the method/token difference turns out to be quite expensive.

      def assert_expr(name)
        (e = send(name)) && (return e)
        raise Sass::SyntaxError.new("Expected expression, was #{@lexer.done? ? 'end of text' : "#{@lexer.peek.type} token"}.")
      end

      def assert_tok(*names)
        (t = try_tok(*names)) && (return t)
        raise Sass::SyntaxError.new("Expected #{names.join(' or ')} token, was #{@lexer.done? ? 'end of text' : "#{@lexer.peek.type} token"}.")
      end

      def try_tok(*names)
        peeked =  @lexer.peek
        peeked && names.include?(peeked.type) && @lexer.next
      end

      def assert_done
        return if @lexer.done?
        raise Sass::SyntaxError.new("Unexpected #{@lexer.peek.type} token.")
      end
    end
  end
end
