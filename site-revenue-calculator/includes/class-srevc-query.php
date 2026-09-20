<?php
defined( 'ABSPATH' ) || exit;

class Srevc_Query {

	public static function is_hpos() {
		if ( class_exists( '\Automattic\WooCommerce\Utilities\OrderUtil' ) && method_exists( '\Automattic\WooCommerce\Utilities\OrderUtil', 'custom_orders_table_usage_is_enabled' ) ) {
			return (bool) \Automattic\WooCommerce\Utilities\OrderUtil::custom_orders_table_usage_is_enabled();
		}
		return false;
	}

	public static function available_statuses() {
		$statuses = array();
		if ( function_exists( 'wc_get_order_statuses' ) ) {
			foreach ( wc_get_order_statuses() as $key => $label ) {
				$statuses[ $key ] = $label;
			}
		}
		return $statuses;
	}

	protected static function prepare( $sql, $args ) {
		global $wpdb;
		if ( empty( $args ) ) {
			return $sql;
		}
		return call_user_func_array( array( $wpdb, 'prepare' ), array_merge( array( $sql ), $args ) );
	}

	protected static function placeholders( $items, $format = '%s' ) {
		return implode( ',', array_fill( 0, count( $items ), $format ) );
	}

	protected static function fetch_orders( $start_gmt, $end_gmt, $statuses ) {
		global $wpdb;

		$status_sql = self::placeholders( $statuses );

		if ( self::is_hpos() ) {
			$table = $wpdb->prefix . 'wc_orders';
			$sql   = "SELECT o.id AS order_id, o.total_amount AS order_total, o.created_via AS created_via, o.payment_method AS payment_method, o.date_created_gmt AS date_created_gmt
				FROM {$table} o
				WHERE o.type = %s
				AND o.status IN ( {$status_sql} )
				AND o.date_created_gmt >= %s
				AND o.date_created_gmt <= %s
				ORDER BY o.date_created_gmt ASC";
			$args  = array_merge( array( 'shop_order' ), $statuses, array( $start_gmt, $end_gmt ) );
		} else {
			$sql  = "SELECT p.ID AS order_id, total_meta.meta_value AS order_total, via_meta.meta_value AS created_via, pay_meta.meta_value AS payment_method, p.post_date_gmt AS date_created_gmt
				FROM {$wpdb->posts} p
				INNER JOIN {$wpdb->postmeta} total_meta ON ( total_meta.post_id = p.ID AND total_meta.meta_key = '_order_total' )
				LEFT JOIN {$wpdb->postmeta} via_meta ON ( via_meta.post_id = p.ID AND via_meta.meta_key = '_created_via' )
				LEFT JOIN {$wpdb->postmeta} pay_meta ON ( pay_meta.post_id = p.ID AND pay_meta.meta_key = '_payment_method' )
				WHERE p.post_type = %s
				AND p.post_status IN ( {$status_sql} )
				AND p.post_date_gmt >= %s
				AND p.post_date_gmt <= %s
				ORDER BY p.post_date_gmt ASC";
			$args = array_merge( array( 'shop_order' ), $statuses, array( $start_gmt, $end_gmt ) );
		}

		$rows = $wpdb->get_results( self::prepare( $sql, $args ) );

		return is_array( $rows ) ? $rows : array();
	}

	protected static function wallet_order_ids( $order_ids, $keywords, $product_ids ) {
		global $wpdb;

		$flagged = array();
		if ( empty( $order_ids ) || ( empty( $keywords ) && empty( $product_ids ) ) ) {
			return $flagged;
		}

		$items_table    = $wpdb->prefix . 'woocommerce_order_items';
		$itemmeta_table = $wpdb->prefix . 'woocommerce_order_itemmeta';
		$chunks         = array_chunk( array_map( 'absint', $order_ids ), 500 );

		foreach ( $chunks as $chunk ) {
			$id_sql = self::placeholders( $chunk, '%d' );

			if ( ! empty( $keywords ) ) {
				$like_parts = array();
				$like_args  = array();
				foreach ( $keywords as $keyword ) {
					$like_parts[] = 'oi.order_item_name LIKE %s';
					$like_args[]  = '%' . $wpdb->esc_like( $keyword ) . '%';
				}
				$sql  = "SELECT DISTINCT oi.order_id AS order_id
					FROM {$items_table} oi
					WHERE oi.order_id IN ( {$id_sql} )
					AND oi.order_item_type = %s
					AND ( " . implode( ' OR ', $like_parts ) . ' )';
				$args = array_merge( $chunk, array( 'line_item' ), $like_args );
				$hits = $wpdb->get_col( self::prepare( $sql, $args ) );
				foreach ( (array) $hits as $hit ) {
					$flagged[ (int) $hit ] = true;
				}
			}

			if ( ! empty( $product_ids ) ) {
				$product_sql = self::placeholders( $product_ids, '%d' );
				$sql         = "SELECT DISTINCT oi.order_id AS order_id
					FROM {$items_table} oi
					INNER JOIN {$itemmeta_table} im ON ( im.order_item_id = oi.order_item_id )
					WHERE oi.order_id IN ( {$id_sql} )
					AND oi.order_item_type = %s
					AND im.meta_key IN ( %s, %s )
					AND im.meta_value IN ( {$product_sql} )";
				$args        = array_merge( $chunk, array( 'line_item', '_product_id', '_variation_id' ), $product_ids );
				$hits        = $wpdb->get_col( self::prepare( $sql, $args ) );
				foreach ( (array) $hits as $hit ) {
					$flagged[ (int) $hit ] = true;
				}
			}
		}

		return $flagged;
	}

	public static function split_list( $value ) {
		$value = str_replace( array( '،', "\n", "\r", ';' ), ',', (string) $value );
		$parts = array_map( 'trim', explode( ',', $value ) );
		return array_values( array_filter( $parts, 'strlen' ) );
	}

	public static function run( $args ) {
		global $wpdb;

		$defaults = array(
			'start'                  => '',
			'end'                    => '',
			'statuses'               => array( 'wc-completed' ),
			'exclude_via'            => array( 'admin' ),
			'exclude_zero'           => true,
			'wallet_keywords'        => array(),
			'wallet_products'        => array(),
			'wallet_gateways'        => array(),
			'exclude_wallet_payment' => false,
		);
		$args = wp_parse_args( $args, $defaults );

		$statuses = array_values( array_unique( array_filter( array_map( 'sanitize_text_field', (array) $args['statuses'] ) ) ) );
		if ( empty( $statuses ) ) {
			$statuses = array( 'wc-completed' );
		}

		$start_gmt = get_gmt_from_date( $args['start'] . ' 00:00:00' );
		$end_gmt   = get_gmt_from_date( $args['end'] . ' 23:59:59' );

		$rows = self::fetch_orders( $start_gmt, $end_gmt, $statuses );

		$exclude_via   = array_map( 'strtolower', array_map( 'trim', (array) $args['exclude_via'] ) );
		$gateways      = array_map( 'strtolower', array_map( 'trim', (array) $args['wallet_gateways'] ) );
		$keywords      = (array) $args['wallet_keywords'];
		$products      = array_map( 'absint', (array) $args['wallet_products'] );
		$products      = array_values( array_filter( $products ) );

		$kept          = array();
		$skipped_zero  = 0;
		$skipped_admin = 0;
		$skipped_wallet_payment = 0;

		foreach ( $rows as $row ) {
			$total = (float) $row->order_total;
			$via   = strtolower( (string) $row->created_via );
			$pay   = strtolower( (string) $row->payment_method );

			if ( ! empty( $args['exclude_zero'] ) && $total <= 0 ) {
				++$skipped_zero;
				continue;
			}
			if ( ! empty( $exclude_via ) && in_array( $via, $exclude_via, true ) ) {
				++$skipped_admin;
				continue;
			}
			if ( ! empty( $args['exclude_wallet_payment'] ) && ! empty( $gateways ) && in_array( $pay, $gateways, true ) ) {
				++$skipped_wallet_payment;
				continue;
			}
			$kept[] = $row;
		}

		$order_ids = wp_list_pluck( $kept, 'order_id' );
		$wallet    = self::wallet_order_ids( $order_ids, $keywords, $products );

		$groups = array();
		$total_revenue = 0.0;
		$wallet_revenue = 0.0;
		$wallet_count   = 0;

		foreach ( $kept as $row ) {
			$amount    = round( (float) $row->order_total, 2 );
			$id        = (int) $row->order_id;
			$is_wallet = isset( $wallet[ $id ] );
			$type      = $is_wallet ? 'wallet' : 'order';
			$key       = $type . '|' . number_format( $amount, 2, '.', '' );

			if ( ! isset( $groups[ $key ] ) ) {
				$groups[ $key ] = array(
					'type'   => $type,
					'amount' => $amount,
					'count'  => 0,
					'sum'    => 0.0,
				);
			}
			++$groups[ $key ]['count'];
			$groups[ $key ]['sum'] += $amount;
			$total_revenue         += $amount;

			if ( $is_wallet ) {
				$wallet_revenue += $amount;
				++$wallet_count;
			}
		}

		$groups = array_values( $groups );
		usort(
			$groups,
			function ( $a, $b ) {
				if ( $a['sum'] === $b['sum'] ) {
					return $b['count'] <=> $a['count'];
				}
				return ( $b['sum'] < $a['sum'] ) ? -1 : 1;
			}
		);

		$count = count( $kept );

		return array(
			'start'                  => $args['start'],
			'end'                    => $args['end'],
			'statuses'               => $statuses,
			'total'                  => $total_revenue,
			'count'                  => $count,
			'average'                => $count > 0 ? ( $total_revenue / $count ) : 0.0,
			'max'                    => $count > 0 ? max( wp_list_pluck( $groups, 'amount' ) ) : 0.0,
			'groups'                 => $groups,
			'wallet_total'           => $wallet_revenue,
			'wallet_count'           => $wallet_count,
			'sales_total'            => $total_revenue - $wallet_revenue,
			'sales_count'            => $count - $wallet_count,
			'skipped_zero'           => $skipped_zero,
			'skipped_admin'          => $skipped_admin,
			'skipped_wallet_payment' => $skipped_wallet_payment,
			'scanned'                => count( $rows ),
			'storage'                => self::is_hpos() ? 'hpos' : 'legacy',
			'db_error'               => $wpdb->last_error,
		);
	}
}
