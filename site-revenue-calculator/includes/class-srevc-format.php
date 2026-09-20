<?php
defined( 'ABSPATH' ) || exit;

class Srevc_Format {

	public static function to_persian_digits( $value ) {
		$latin   = array( '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' );
		$persian = array( '۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹' );
		return str_replace( $latin, $persian, (string) $value );
	}

	public static function display_value( $amount, $settings ) {
		$amount = (float) $amount;
		if ( ! empty( $settings['divide_by_ten'] ) ) {
			$amount = $amount / 10;
		}
		return $amount;
	}

	public static function number( $amount, $settings ) {
		$value    = self::display_value( $amount, $settings );
		$value    = round( $value, 2 );
		$decimals = ( 0.0 === (float) fmod( $value, 1 ) ) ? 0 : 2;
		$output   = number_format( $value, $decimals, '.', ',' );
		if ( ! empty( $settings['persian_digits'] ) ) {
			$output = self::to_persian_digits( $output );
		}
		return $output;
	}

	public static function raw_number( $amount, $settings ) {
		$value = round( self::display_value( $amount, $settings ), 2 );
		$decimals = ( 0.0 === (float) fmod( $value, 1 ) ) ? 0 : 2;
		return number_format( $value, $decimals, '.', '' );
	}

	public static function money( $amount, $settings ) {
		$label = isset( $settings['currency_label'] ) ? $settings['currency_label'] : '';
		return trim( self::number( $amount, $settings ) . ' ' . $label );
	}

	public static function money_words( $amount, $settings ) {
		$value = self::display_value( $amount, $settings );
		$label = isset( $settings['currency_label'] ) ? $settings['currency_label'] : '';
		$abs   = abs( $value );

		$units = array(
			array( 1000000000, 'میلیارد' ),
			array( 1000000, 'میلیون' ),
			array( 1000, 'هزار' ),
		);

		foreach ( $units as $unit ) {
			if ( $abs < $unit[0] ) {
				continue;
			}
			$scaled = $value / $unit[0];
			for ( $decimals = 0; $decimals <= 2; $decimals++ ) {
				$rounded = round( $scaled, $decimals );
				if ( abs( ( $rounded * $unit[0] ) - $value ) < 0.01 ) {
					$output = number_format( $rounded, $decimals, '.', ',' );
					if ( ! empty( $settings['persian_digits'] ) ) {
						$output = self::to_persian_digits( $output );
					}
					return trim( $output . ' ' . $unit[1] . ' ' . $label );
				}
			}
			break;
		}

		return self::money( $amount, $settings );
	}

	public static function count_label( $count, $settings ) {
		$output = number_format( (int) $count, 0, '.', ',' );
		if ( ! empty( $settings['persian_digits'] ) ) {
			$output = self::to_persian_digits( $output );
		}
		return $output;
	}

	public static function percent( $part, $whole, $settings ) {
		$whole = (float) $whole;
		if ( $whole <= 0 ) {
			return self::count_label( 0, $settings ) . '٪';
		}
		$value  = round( ( (float) $part / $whole ) * 100, 1 );
		$output = number_format( $value, ( 0.0 === (float) fmod( $value, 1 ) ) ? 0 : 1, '.', '' );
		if ( ! empty( $settings['persian_digits'] ) ) {
			$output = self::to_persian_digits( $output );
		}
		return $output . '٪';
	}
}
